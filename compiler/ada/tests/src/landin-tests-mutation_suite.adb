--  One mistake, one report.
--
--  Every body line of the clean single-file positive programs is changed
--  by one token, and the refused mutants are held to what a reader needs
--  from a report: one of them, on the changed line, inside the function
--  the mistake is in, never claiming that a closer the program still
--  writes is missing, and with its primary span on a token.  The changes
--  are the ones people make by accident: a token deleted, written twice,
--  swapped with its neighbour, or a stray word inserted before it.
--
--  Which token of a line changes, and how, is drawn from a fixed seed, so
--  every host, build mode and run makes the same mutants.  Each is
--  compiled through the whole driver against a fake filesystem holding
--  only the mutant; reading the corpus and writing the observations are
--  this suite's deliberate real-host exceptions.

with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Diagnostics.Lexical;
with Landin.Driver;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Source;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax;
with Landin.Syntax.Parser;
with Landin.Testing.Fakes;
with Landin.Testing.Fixes;
with Landin.Testing.Fixtures;
with Landin.Tokens;
with Landin.Tokens.Lexer;

package body Landin.Tests.Mutation_Suite is

   package Diag renames Landin.Diagnostics;
   package Fixtures renames Landin.Testing.Fixtures;
   package Unbounded renames Ada.Strings.Unbounded;
   package Tok renames Landin.Tokens;

   use type Diag.Severity;
   use type Fixtures.Fixture_Class;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Span;
   use type Landin.Syntax.Node_Kind;
   use type Tok.Token_Kind;

   Corpus : constant String := "../tests/fixtures";

   --  Inside this host's own build tree, as every native case writes.
   Scratch : constant String :=
     "build/"
     & Ada.Environment_Variables.Value ("LANDIN_BUILD_TAG", "host")
     & "/"
     & Ada.Environment_Variables.Value ("LANDIN_BUILD_MODE", "debug")
     & "/test-scratch";

   LF : constant Character := Character'Val (10);

   ------------------------------------------------------------------
   --  The generator
   ------------------------------------------------------------------

   --  Xorshift32, as the parser suite's campaign uses, with a seed of its
   --  own: the two campaigns choose independently.
   type Word is mod 2 ** 32;
   Seed : constant Word := 16#1126_0001#;

   function Draw (State : in out Word; Limit : Positive) return Positive;

   function Draw (State : in out Word; Limit : Positive) return Positive is
   begin
      State := State xor (State * 2 ** 13);
      State := State xor (State / 2 ** 17);
      State := State xor (State * 2 ** 5);
      return Positive (Natural (State mod Word (Limit)) + 1);
   end Draw;

   type Change is (Deleted, Doubled, Swapped, Inserted);

   --  The stray words a hand inserts: a word from another language, a
   --  keyword out of place, and the punctuation most often mistyped.
   type Stray_Index is range 1 .. 9;

   function Stray (Index : Stray_Index) return String
     is (case Index is
            when 1 => "mut",
            when 2 => "let",
            when 3 => "as",
            when 4 => "then",
            when 5 => "end",
            when 6 => "(",
            when 7 => ")",
            when 8 => ",",
            when 9 => "=");

   --  The words that close or open a construct.  A report that a construct
   --  is never closed is a claim about a closer; it is excused only when
   --  the change took a closer away or added an opener, and otherwise the
   --  closer it says is missing is still written.
   function Opens_Or_Closes (Text : String) return Boolean
     is (Text in "end" | "(" | ")" | "[" | "]" | "if" | "match" | "loop"
              | "while" | "for" | "begin" | "unchecked" | "struct" | "do");

   ------------------------------------------------------------------
   --  What a mutant is measured by
   ------------------------------------------------------------------

   type Tally is record
      Mutants    : Natural := 0;
      Accepted   : Natural := 0;
      Refused    : Natural := 0;
      One_Report : Natural := 0;
      One_On_Line : Natural := 0;
      First_On_Line : Natural := 0;
      First_Near : Natural := 0;
      Outside    : Natural := 0;
      False_Unclosed : Natural := 0;
      Begins_No_Declaration : Natural := 0;
      Off_Token  : Natural := 0;
      Repeated_Secondary : Natural := 0;
      Reports    : Natural := 0;
      Defects    : Natural := 0;
      Repaired   : Natural := 0;
      Repair_Parses : Natural := 0;
      Repair_Restores : Natural := 0;
   end record;

   --  The bounds the suite holds the compiler to.  The share is what the
   --  work this suite measures must reach; the floor and ceilings are what
   --  the compiler measured when it was last improved, so a change can only
   --  move them towards that share and never back.  The first measurement,
   --  of 1,829 refused mutants, gave 596 one report on the changed line,
   --  43 reporting outside their function, 521 reading the rest of the body
   --  as declarations, 406 claiming a written closer missing and 1,108 with
   --  a primary span off a token.  Recovery that keeps to the structure the
   --  program writes took those to 1,309, 21, 1, 18 and 493, and putting a
   --  missing token's report on the token found instead to 1,403 and 146.
   --  Reporting a refused statement as the smallest change that mends it
   --  took them to 1,449 and 88.  Recovery that never reads past the
   --  closer of the function it is in took them to 1,495 and 59, and
   --  left none outside its function, leaving its body, or claiming that
   --  a closer it has is missing: those three are held at zero, as the
   --  exit evidence requires.  Set LANDIN_MUTATION_TRACE to log each
   --  repair that does not give back the program the mutant came from,
   --  and LANDIN_MUTATION_KEEP=name:line to keep that mutant's text in
   --  the scratch directory as kept-mutant.ldn.
   Exit_Share_Percent : constant := 90;
   Floor_One_On_Line  : constant := 1_495;
   Ceiling_Off_Token  : constant := 59;

   function Image (Value : Natural) return String
     is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Percent (Part, Whole : Natural) return Natural
     is (if Whole = 0 then 0 else Part * 100 / Whole);

   --  The line, from one, that a byte offset is on.
   function Line_Of (Text : String; Offset : Landin.Source.Byte_Offset)
     return Positive;

   function Line_Of (Text : String; Offset : Landin.Source.Byte_Offset)
     return Positive
   is
      Line : Positive := 1;
   begin
      for Index in Text'First
                   .. Text'First + Natural (Offset) - 1
      loop
         exit when Index > Text'Last;
         if Text (Index) = LF then
            Line := Line + 1;
         end if;
      end loop;
      return Line;
   end Line_Of;

   --  Line Line of Text, without its line end.
   function Line_Text (Text : String; Line : Positive) return String;

   function Line_Text (Text : String; Line : Positive) return String is
      Seen  : Positive := 1;
      First : Natural := Text'First;
   begin
      for Index in Text'Range loop
         if Seen = Line then
            First := Index;
            exit;
         end if;
         if Text (Index) = LF then
            Seen := Seen + 1;
         end if;
      end loop;
      for Index in First .. Text'Last loop
         if Text (Index) = LF then
            return Text (First .. Index - 1);
         end if;
      end loop;
      return Text (First .. Text'Last);
   end Line_Text;

   ------------------------------------------------------------------
   --  The campaign
   ------------------------------------------------------------------

   procedure One_Mistake_Gives_One_Report
     (Item : in out Landin.Testing.Context);

   procedure One_Mistake_Gives_One_Report
     (Item : in out Landin.Testing.Context)
   is
      Real      : Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      State     : Word := Seed;
      Counted   : Tally;
      Log       : Unbounded.Unbounded_String;
      Programs  : Natural := 0;

      --  Every token of a program's text, and whether it lies in a
      --  function body; with the extent of the function each body token
      --  belongs to.
      type Token_Fact is record
         Where    : Landin.Source.Span;
         Line     : Positive := 1;
         In_Body  : Boolean := False;
         Function_At : Landin.Source.Span := Landin.Source.Empty_Span;
      end record;

      type Token_Facts is array (Positive range <>) of Token_Fact;

      procedure Measure
        (Label    : String;
         Original : String;
         Line     : Positive;
         Kind     : Change;
         Touched  : String;
         Excused  : Boolean;
         Mutant   : String;
         Within   : Landin.Source.Span);

      procedure Measure
        (Label    : String;
         Original : String;
         Line     : Positive;
         Kind     : Change;
         Touched  : String;
         Excused  : Boolean;
         Mutant   : String;
         Within   : Landin.Source.Span)
      is
         Host  : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Arguments : Landin.Platform.Path_List;
         Ran   : Landin.Driver.Outcome;
         Errors : Natural := 0;
         First_Line : Natural := 0;
         Codes : Unbounded.Unbounded_String;
         Flags : Unbounded.Unbounded_String;
         Outside, Unclosed, No_Declaration, Off_Token, Repeated :
           Boolean := False;

         --  Mutant token boundaries, for the on-a-token rule.
         Starts, Ends : array (0 .. Mutant'Length) of Boolean :=
           [others => False];
      begin
         declare
            Sources : Landin.Source.Sets.Source_Set;
            Names   : Landin.Source.Names.Table;
            Stream  : Tok.Token_Stream;
            Id      : constant Landin.Source.Source_Id :=
              Sources.Add ("mutant.ldn", Mutant);
         begin
            Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
            for Index in 1 .. Tok.Count (Stream) loop
               if Tok.Kind (Stream, Index) /= Tok.End_Of_Input then
                  Starts (Natural (Tok.Where (Stream, Index).First)) := True;
                  Ends (Natural (Tok.Where (Stream, Index).Last)) := True;
               end if;
            end loop;
         end;

         if Ada.Environment_Variables.Exists ("LANDIN_MUTATION_KEEP")
           and then Label & ":" & Image (Line)
             = Ada.Environment_Variables.Value ("LANDIN_MUTATION_KEEP")
         then
            declare
               Kept : Landin.Platform.Write_Status;
            begin
               Real.Write_File
                 (Scratch & "/kept-mutant.ldn", Mutant, Kept);
            end;
         end if;
         Host.Add_File ("mutant.ldn", Mutant);
         Arguments.Append ("--target=linux-x86-64");
         Arguments.Append ("mutant.ldn");
         Ran := Landin.Driver.Execute (Arguments, Host, Tools);

         Counted.Mutants := Counted.Mutants + 1;

         --  A single-token repair claims the program parses with it; hold
         --  the first one offered to that, and count how often it gives
         --  back the program the mutant was made from.
         if Diag.Count (Ran.Found) > 0
           and then Diag.Fix_Count (Diag.Get (Ran.Found, 1)) > 0
           and then Diag.Kind (Diag.Nth_Fix (Diag.Get (Ran.Found, 1), 1))
             in Diag.Delete_Token | Diag.Insert_Token | Diag.Swap_Tokens
              | Diag.Move_Token
         then
            declare
               Only_First : Diag.Diagnostic_List;
               Clashed : Boolean;
            begin
               Only_First.Append (Diag.Get (Ran.Found, 1));
               declare
                  Fixed : constant String :=
                    Landin.Testing.Fixes.Applied
                      (Only_First, 1, Mutant, Clashed);
                  Sources : Landin.Source.Sets.Source_Set;
                  Names   : Landin.Source.Names.Table;
                  Stream  : Tok.Token_Stream;
                  Found   : Diag.Diagnostic_List;
                  Id      : constant Landin.Source.Source_Id :=
                    Sources.Add ("fixed.ldn", Fixed);
               begin
                  Counted.Repaired := Counted.Repaired + 1;
                  Tok.Lexer.Lex (Sources.Get (Id), Names, Stream);
                  Landin.Diagnostics.Lexical.Report (Stream, Found);
                  declare
                     Parsed : constant Landin.Syntax.Tree :=
                       Landin.Syntax.Parser.Parse (Stream, Names, Found);
                     pragma Unreferenced (Parsed);
                  begin
                     --  The repair mends its line; a mistake the change
                     --  made elsewhere, such as a label it took from a
                     --  later `break`, is that line's own report.
                     if not Clashed
                       and then
                         (for all Index in 1 .. Diag.Count (Found) =>
                            Diag.Level (Diag.Get (Found, Index)) /= Diag.Error
                            or else Line_Of
                              (Fixed,
                               Diag.Span_Of (Diag.Primary
                                 (Diag.Get (Found, Index))).First) > Line)
                     then
                        Counted.Repair_Parses := Counted.Repair_Parses + 1;
                     else
                        Landin.Testing.Fail
                          (Item, Label & ":" & Image (Line) & " "
                           & Kind'Image & " `" & Touched
                           & "`: the offered repair does not parse");
                     end if;
                  end;
                  if Fixed = Original then
                     Counted.Repair_Restores :=
                       Counted.Repair_Restores + 1;
                  elsif Ada.Environment_Variables.Exists
                          ("LANDIN_MUTATION_TRACE")
                  then
                     Unbounded.Append
                       (Log, "TRACE " & Label & ":" & Image (Line) & LF
                        & "  mutant: " & Line_Text (Mutant, Line) & LF
                        & "  fixed:  " & Line_Text (Fixed, Line) & LF
                        & "  was:    " & Line_Text (Original, Line) & LF);
                  end if;
               end;
            end;
         end if;

         if Ran.Status = Landin.Driver.Status_Defect then
            Counted.Defects := Counted.Defects + 1;
            Landin.Testing.Fail
              (Item, Label & ":" & Image (Line) & " " & Kind'Image
               & " `" & Touched & "` raised a compiler defect");
         end if;

         for Index in 1 .. Diag.Count (Ran.Found) loop
            declare
               Report  : constant Diag.Diagnostic :=
                 Diag.Get (Ran.Found, Index);
               Primary : constant Diag.Label := Diag.Primary (Report);
               Where   : constant Landin.Source.Span :=
                 Diag.Span_Of (Primary);
            begin
               if Diag.Level (Report) = Diag.Error then
                  Errors := Errors + 1;
                  if Errors > 1 then
                     Unbounded.Append (Codes, ",");
                  end if;
                  Unbounded.Append (Codes, Diag.Code (Report));

                  if Diag.Source_Of (Primary) = 1 then
                     if Errors = 1 then
                        First_Line := Line_Of (Mutant, Where.First);
                     end if;

                     if Where.First < Within.First
                       or else Where.Last > Within.Last
                     then
                        Outside := True;
                     end if;

                     if Natural (Where.Last) > Mutant'Length
                       or else Where.First = Where.Last
                       or else not Starts (Natural (Where.First))
                       or else not Ends (Natural (Where.Last))
                     then
                        Off_Token := True;
                     end if;

                     for Extra in 1 .. Diag.Label_Count (Report) loop
                        declare
                           Other : constant Diag.Label :=
                             Diag.Nth_Label (Report, Extra);
                        begin
                           if Diag.Source_Of (Other) = 1
                             and then Diag.Span_Of (Other) = Where
                           then
                              Repeated := True;
                           end if;
                        end;
                     end loop;
                  end if;

                  if Diag.Code (Report) = "L0104" and then not Excused then
                     Unclosed := True;
                  end if;
                  --  The parser read the rest of the body as the
                  --  declarations of a file, wherever the report lands.
                  if Diag.Message (Primary) = "this begins no declaration"
                  then
                     No_Declaration := True;
                  end if;
               end if;
            end;
         end loop;

         if Errors = 0 then
            Counted.Accepted := Counted.Accepted + 1;
            return;
         end if;

         Counted.Refused := Counted.Refused + 1;
         Counted.Reports := Counted.Reports + Errors;
         if Errors = 1 then
            Counted.One_Report := Counted.One_Report + 1;
            if First_Line = Line then
               Counted.One_On_Line := Counted.One_On_Line + 1;
            end if;
         end if;
         if First_Line = Line then
            Counted.First_On_Line := Counted.First_On_Line + 1;
         end if;
         if First_Line in Line - 1 .. Line + 1 then
            Counted.First_Near := Counted.First_Near + 1;
         end if;
         if Outside then
            Counted.Outside := Counted.Outside + 1;
            Unbounded.Append (Flags, " outside");
         end if;
         if Unclosed then
            Counted.False_Unclosed := Counted.False_Unclosed + 1;
            Unbounded.Append (Flags, " false-unclosed");
         end if;
         if No_Declaration then
            Counted.Begins_No_Declaration :=
              Counted.Begins_No_Declaration + 1;
            Unbounded.Append (Flags, " left-the-body");
         end if;
         if Off_Token then
            Counted.Off_Token := Counted.Off_Token + 1;
            Unbounded.Append (Flags, " off-token");
         end if;
         if Repeated then
            Counted.Repeated_Secondary := Counted.Repeated_Secondary + 1;
            Unbounded.Append (Flags, " repeated-secondary");
         end if;
         if Errors /= 1 or else First_Line /= Line then
            Unbounded.Append (Flags, " not-one-on-line");
         end if;

         Unbounded.Append
           (Log,
            Label & ":" & Image (Line) & " " & Kind'Image & " `" & Touched
            & "` -> " & Image (Errors) & " [" & Unbounded.To_String (Codes)
            & "] first line " & Image (First_Line)
            & Unbounded.To_String (Flags) & LF);
      end Measure;

      procedure Campaign (Fixture : Fixtures.Fixture);

      procedure Campaign (Fixture : Fixtures.Fixture) is
         Label : constant String := Fixtures.Name (Fixture);
         Path  : constant String :=
           Corpus & "/positive/" & Label & "/" & Fixtures.Program (Fixture);
         Content : Unbounded.Unbounded_String;
         Status  : Landin.Platform.Read_Status;
      begin
         Real.Read_File (Path, Content, Status);
         if Status /= Landin.Platform.Read_Ok then
            Landin.Testing.Fail (Item, Path & " is unreadable");
            return;
         end if;

         declare
            Text    : constant String := Unbounded.To_String (Content);
            Sources : Landin.Source.Sets.Source_Set;
            Names   : Landin.Source.Names.Table;
            Stream  : Tok.Token_Stream;
            Found   : Diag.Diagnostic_List;
            Id      : constant Landin.Source.Source_Id :=
              Sources.Add (Path, Text);
         begin
            Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
            Landin.Diagnostics.Lexical.Report (Stream, Found);

            declare
               Parsed : constant Landin.Syntax.Tree :=
                 Landin.Syntax.Parser.Parse (Stream, Names, Found);
               Count  : constant Natural :=
                 Natural (Tok.Count (Stream)) - 1;
               Facts  : Token_Facts (1 .. Count);
               Last_Line : Natural := 0;
            begin
               if Diag.Has_Errors (Found) then
                  Landin.Testing.Fail
                    (Item, Label & ": the clean program does not parse");
                  return;
               end if;

               declare
                  Line : Positive := 1;
                  Scanned : Natural := Text'First;
               begin
                  for Index in 1 .. Count loop
                     Facts (Index).Where :=
                       Tok.Where (Stream, Tok.Token_Index (Index));
                     while Scanned
                       < Text'First + Natural (Facts (Index).Where.First)
                     loop
                        if Text (Scanned) = LF then
                           Line := Line + 1;
                        end if;
                        Scanned := Scanned + 1;
                     end loop;
                     Facts (Index).Line := Line;
                  end loop;
               end;

               for Node in Landin.Syntax.Node_Id'(1)
                           .. Landin.Syntax.Last_Node (Parsed)
               loop
                  if Landin.Syntax.Kind (Parsed, Node)
                       = Landin.Syntax.Function_Declaration
                    and then not Landin.Syntax.Is_External (Parsed, Node)
                  then
                     declare
                        Body_At : constant Landin.Source.Span :=
                          Landin.Syntax.Where
                            (Parsed, Landin.Syntax.Body_Of (Parsed, Node));
                        Whole : constant Landin.Source.Span :=
                          Landin.Syntax.Where (Parsed, Node);
                     begin
                        for Fact of Facts loop
                           if Landin.Source.Contains (Body_At, Fact.Where)
                             and then Fact.Where.First /= Fact.Where.Last
                           then
                              Fact.In_Body := True;
                              Fact.Function_At := Whole;
                           end if;
                        end loop;
                     end;
                  end if;
               end loop;

               Programs := Programs + 1;

               --  One mutant per body line: the line's first body token
               --  and its last bound the draw.
               for First in Facts'Range loop
                  if Facts (First).In_Body then
                     declare
                        Line : constant Positive := Facts (First).Line;
                        Last : Positive := First;
                     begin
                        if Line /= Last_Line then
                           Last_Line := Line;
                           while Last < Facts'Last
                             and then Facts (Last + 1).In_Body
                             and then Facts (Last + 1).Line = Line
                           loop
                              Last := Last + 1;
                           end loop;

                           declare
                              At_Token : constant Positive :=
                                First + Draw (State, Last - First + 1) - 1;
                              Kind : Change :=
                                Change'Val (Draw (State, 4) - 1);
                              Chosen : constant Stray_Index :=
                                Stray_Index
                                  (Draw (State, Positive (Stray_Index'Last)));
                              Here : constant Token_Fact := Facts (At_Token);
                              F : constant Natural :=
                                Text'First + Natural (Here.Where.First);
                              L : constant Natural :=
                                Text'First + Natural (Here.Where.Last);
                              Spelled : constant String := Text (F .. L - 1);
                              Within : Landin.Source.Span :=
                                Here.Function_At;
                              Mutant : Unbounded.Unbounded_String;
                              Touched : Unbounded.Unbounded_String;
                              Excused : Boolean := False;
                           begin
                              if Kind = Swapped and then At_Token = Last then
                                 Kind := (if First = Last then Inserted
                                          else Deleted);
                              end if;

                              case Kind is
                                 when Deleted =>
                                    Mutant := Unbounded.To_Unbounded_String
                                      (Text (Text'First .. F - 1)
                                       & Text (L .. Text'Last));
                                    Touched :=
                                      Unbounded.To_Unbounded_String (Spelled);
                                    Excused := Opens_Or_Closes (Spelled);
                                    Within.Last := Within.Last
                                      - Landin.Source.Byte_Offset
                                          (Spelled'Length);
                                 when Doubled =>
                                    Mutant := Unbounded.To_Unbounded_String
                                      (Text (Text'First .. L - 1) & " "
                                       & Spelled & Text (L .. Text'Last));
                                    Touched :=
                                      Unbounded.To_Unbounded_String (Spelled);
                                    Excused := Opens_Or_Closes (Spelled);
                                    Within.Last := Within.Last
                                      + Landin.Source.Byte_Offset
                                          (Spelled'Length + 1);
                                 when Swapped =>
                                    declare
                                       Next : constant Token_Fact :=
                                         Facts (At_Token + 1);
                                       F2 : constant Natural :=
                                         Text'First
                                         + Natural (Next.Where.First);
                                       L2 : constant Natural :=
                                         Text'First
                                         + Natural (Next.Where.Last);
                                    begin
                                       Mutant := Unbounded.To_Unbounded_String
                                         (Text (Text'First .. F - 1)
                                          & Text (F2 .. L2 - 1)
                                          & Text (L .. F2 - 1)
                                          & Spelled
                                          & Text (L2 .. Text'Last));
                                       Touched :=
                                         Unbounded.To_Unbounded_String
                                           (Spelled & " "
                                            & Text (F2 .. L2 - 1));
                                       Excused := Opens_Or_Closes (Spelled)
                                         or else Opens_Or_Closes
                                           (Text (F2 .. L2 - 1));
                                    end;
                                 when Inserted =>
                                    Mutant := Unbounded.To_Unbounded_String
                                      (Text (Text'First .. F - 1)
                                       & Stray (Chosen) & " "
                                       & Text (F .. Text'Last));
                                    Touched := Unbounded.To_Unbounded_String
                                      (Stray (Chosen));
                                    Excused := Opens_Or_Closes
                                      (Stray (Chosen));
                                    Within.Last := Within.Last
                                      + Landin.Source.Byte_Offset
                                          (Stray (Chosen)'Length + 1);
                              end case;

                              Measure
                                (Label, Text, Line, Kind,
                                 Unbounded.To_String (Touched), Excused,
                                 Unbounded.To_String (Mutant), Within);
                           end;
                        end if;
                     end;
                  end if;
               end loop;
            end;
         end;
      end Campaign;
   begin
      Fixtures.Discover (Catalogue, Corpus, Real);

      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
         begin
            if Fixtures.Class (Fixture) = Fixtures.Positive_Program
              and then Fixtures.Program (Fixture) /= ""
              and then Fixtures.Module_Root (Fixture) = ""
              and then Fixtures.With_Sources (Fixture) = ""
              and then Fixtures.Args (Fixture) = ""
            then
               Campaign (Fixture);
            end if;
         end;
      end loop;

      declare
         Summary : constant String :=
           "programs " & Image (Programs)
           & ", mutants " & Image (Counted.Mutants)
           & ", accepted " & Image (Counted.Accepted)
           & ", refused " & Image (Counted.Refused)
           & ", reports " & Image (Counted.Reports)
           & ", exactly one " & Image (Counted.One_Report)
           & " (" & Image (Percent (Counted.One_Report, Counted.Refused))
           & "%), one on the line " & Image (Counted.One_On_Line)
           & " (" & Image (Percent (Counted.One_On_Line, Counted.Refused))
           & "%), first on the line " & Image (Counted.First_On_Line)
           & " (" & Image (Percent (Counted.First_On_Line, Counted.Refused))
           & "%), within a line of it " & Image (Counted.First_Near)
           & " (" & Image (Percent (Counted.First_Near, Counted.Refused))
           & "%), outside the function " & Image (Counted.Outside)
           & ", left the body " & Image
               (Counted.Begins_No_Declaration)
           & ", false never-closed " & Image (Counted.False_Unclosed)
           & ", primary off a token " & Image (Counted.Off_Token)
           & ", secondary repeating the primary "
           & Image (Counted.Repeated_Secondary)
           & ", defects " & Image (Counted.Defects)
           & ", single-token repairs offered " & Image (Counted.Repaired)
           & " (" & Image (Counted.Repair_Parses) & " parse, "
           & Image (Counted.Repair_Restores) & " give back the program)"
           & "; the exit asks for " & Image (Exit_Share_Percent)
           & "% one on the line";
         Written : Landin.Platform.Write_Status;
      begin
         Ada.Directories.Create_Path (Scratch);
         Real.Write_File
           (Scratch & "/mutation-observations.txt",
            Summary & LF & Unbounded.To_String (Log), Written);
         Landin.Testing.Check
           (Item, Written = Landin.Platform.Write_Ok,
            "the observations are written to " & Scratch);

         Landin.Testing.Check
           (Item, Programs > 200 and then Counted.Refused > 1_000,
            "the campaign covers the corpus: " & Summary);
         Landin.Testing.Check
           (Item, Counted.One_On_Line >= Floor_One_On_Line,
            "no fewer mutants than before give one report on their line: "
            & Summary);
         Landin.Testing.Check_Equal
           (Item, Counted.Outside, 0,
            "no mutant reports outside its function");
         Landin.Testing.Check_Equal
           (Item, Counted.Begins_No_Declaration, 0,
            "no mutant leaves the body it is in");
         Landin.Testing.Check_Equal
           (Item, Counted.False_Unclosed, 0,
            "no mutant claims that a closer it has is missing");
         Landin.Testing.Check
           (Item, Counted.Off_Token <= Ceiling_Off_Token,
            "no more primary spans than before miss a token: " & Summary);
         Landin.Testing.Check_Equal
           (Item, Counted.Repeated_Secondary, 0,
            "no secondary label repeats its primary span");
      end;
   end One_Mistake_Gives_One_Report;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "mutation", "one mistake gives one report",
         One_Mistake_Gives_One_Report'Access);
   end Register;

end Landin.Tests.Mutation_Suite;
