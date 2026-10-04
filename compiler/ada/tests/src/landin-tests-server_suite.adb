--  The language server.
--
--  The stand-in first, because everything a server says past a syntax
--  error rests on it: what it replaces, what it refuses to replace, and
--  that an analysis says what `refine` says about every program it can
--  compile.  The corpus cases read the real fixture tree and the fuzzer's
--  reproducers, which is their deliberate exception to the fake host.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Driver;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Server.Analysis;
with Landin.Server.Documents;
with Landin.Server.Holes;
with Landin.Server.Navigation;
with Landin.Server.Positions;
with Landin.Server.Sessions;
with Landin.Server.Transport;
with Landin.Json;
with Landin.Source;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Stages;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Targets.Levels;
with Landin.Testing.Fakes;
with Landin.Testing.Sessions;
with Landin.Testing.Fixtures;
with Landin.Tokens;
with Landin.Tokens.Lexer;
with Landin.Tokens.Spacing;

package body Landin.Tests.Server_Suite is

   package Diag renames Landin.Diagnostics;
   package Fixtures renames Landin.Testing.Fixtures;
   package Holes renames Landin.Server.Holes;
   package Transport renames Landin.Server.Transport;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Holes.Verdict;
   use type Transport.Status;
   use type Landin.Server.Positions.Position;
   use type Landin.Server.Navigation.Place;
   use type Landin.Source.Byte_Offset;
   use type Landin.Platform.Write_Status;
   use type Landin.Source.Span;
   use type Fixtures.Fixture_Class;

   LF : constant Character := ASCII.LF;

   Corpus : constant String := "../tests/fixtures";
   Reproducers : constant String := "../tests/fuzz/reproducers";

   --  Every code in a report, warnings included, in order.
   function Codes_Of (Found : Diag.Diagnostic_List) return String;

   function Codes_Of (Found : Diag.Diagnostic_List) return String is
      Text : Unbounded.Unbounded_String;
   begin
      for Index in 1 .. Found.Count loop
         if Index > 1 then
            Unbounded.Append (Text, ", ");
         end if;
         Unbounded.Append (Text, Diag.Code (Found.Get (Index)));
      end loop;
      return Unbounded.To_String (Text);
   end Codes_Of;

   --  Analyse Files as a module over Host, as a server would.
   function Analysed
     (Host  : Landin.Platform.Filesystem'Class;
      Asked : Landin.Server.Analysis.Request)
      return Landin.Server.Analysis.Result;

   function Analysed
     (Host  : Landin.Platform.Filesystem'Class;
      Asked : Landin.Server.Analysis.Request)
      return Landin.Server.Analysis.Result
   is
      Answer  : Landin.Server.Analysis.Result;
      procedure Visit
        (Context : in out Landin.Stages.Compilation;
         Result  : Landin.Server.Analysis.Result);

      procedure Visit
        (Context : in out Landin.Stages.Compilation;
         Result  : Landin.Server.Analysis.Result)
      is
         pragma Unreferenced (Context);
      begin
         Answer := Result;
      end Visit;
   begin
      Landin.Server.Analysis.Analyse
        (Landin.Targets.Linux_X86_64,
         Landin.Targets.Levels.Default_Level
           (Landin.Targets.Linux_X86_64),
         Host, Asked, Visit'Access);
      return Answer;
   end Analysed;

   function One_File (Path : String) return Landin.Server.Analysis.Request
     is (Files => Landin.Platform.Arguments (Path), others => <>);

   ---------------------------------------------------------------------
   --  The stand-in
   ---------------------------------------------------------------------

   procedure A_Broken_Body_Is_Stood_In_For
     (Item : in out Landin.Testing.Context);

   procedure A_Broken_Body_Is_Stood_In_For
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "sum: (x: u8, y: u8) -> (z: u8) =" & LF
        & "    z = x + y * 3 -" & LF
        & "end sum" & LF;
      Plan : constant Holes.Plan := Holes.Plan_For (Text);
   begin
      Landin.Testing.Check
        (Item, Plan.Outcome = Holes.Stood_In, "the body is stood in for");
      Landin.Testing.Check_Equal
        (Item, Plan.Text,
         "sum: (x: u8, y: u8) -> (z: u8) =" & LF
         & "loop do end loop   " & LF
         & "end sum" & LF,
         "its bytes are blanks and the stand-in, its line ends kept");
      Landin.Testing.Check_Equal
        (Item, Natural (Plan.Held.Length), 1, "one region is held");
      Landin.Testing.Check
        (Item, Plan.Held.First_Element = (32, 56),
         "from after `=` to the end of `end`");
      Landin.Testing.Check
        (Item, Holes.Plan_For ("f: () -> none = end f" & LF).Outcome
               = Holes.Sound,
         "a source that parses is analysed as it is");
   end A_Broken_Body_Is_Stood_In_For;

   procedure Several_Broken_Bodies_Are_Stood_In_For
     (Item : in out Landin.Testing.Context);

   procedure Several_Broken_Bodies_Are_Stood_In_For
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "first: () -> none =" & LF
        & "    x := 1 + 2 * 3 -" & LF
        & "end first" & LF
        & "sound: () -> none = end sound" & LF
        & "second: () -> none =" & LF
        & "    x := 2 + 3 * 4 -" & LF
        & "end second" & LF
        & "third: () -> none =" & LF
        & "    x := 3 + 4 * 5 -" & LF
        & "end third" & LF;
      Plan : constant Holes.Plan := Holes.Plan_For (Text);
   begin
      Landin.Testing.Check
        (Item, Plan.Outcome = Holes.Stood_In,
         "all broken bodies can be stood in for");
      Landin.Testing.Check_Equal
        (Item, Natural (Plan.Held.Length), 3,
         "one held region per broken body");
      if Natural (Plan.Held.Length) = 3 then
         Landin.Testing.Check
           (Item, Plan.Held.Element (1).Last < Plan.Held.Element (2).First
                  and then Plan.Held.Element (2).Last
                    < Plan.Held.Element (3).First,
            "held regions stay in source order across a sound body");
      end if;
      Landin.Testing.Check_Equal
        (Item, Ada.Strings.Fixed.Count (Plan.Text, "loop do end loop"), 3,
         "each broken body receives a stand-in");
   end Several_Broken_Bodies_Are_Stood_In_For;

   --  Each source here has an error a stand-in must not hide.
   procedure Only_A_Body_Is_Stood_In_For
     (Item : in out Landin.Testing.Context);

   procedure Only_A_Body_Is_Stood_In_For
     (Item : in out Landin.Testing.Context)
   is
      procedure Refused (Text : String; Why : String);

      procedure Refused (Text : String; Why : String) is
         Plan : constant Holes.Plan := Holes.Plan_For (Text);
      begin
         Landin.Testing.Check
           (Item, Plan.Outcome = Holes.Refused and then Plan.Held.Is_Empty
                  and then Plan.Text = Text,
            Why);
      end Refused;
   begin
      Refused ("f: (x: ) -> none = end f" & LF,
               "a hole in the parameters");
      Refused ("f: () -> (y: ) = loop do end loop end f" & LF,
               "a hole in the results");
      Refused ("f: () -> none =" & LF & "    x := 1 +" & LF & LF
               & "g: () -> none = end g" & LF,
               "a body the parser never closed");
      Refused ("f: () -> (y: u8) ! ... =" & LF & "    y = (" & LF
               & "end f" & LF,
               "an inferred error set, which the body decides");
      Refused ("f: (t: type, x: t) -> (y: t) =" & LF & "    y = (" & LF
               & "end f" & LF,
               "a generic");
      Refused ("f: () -> none =" & LF & "    x := (" & LF
               & "g: () -> none = end g" & LF & "end f" & LF,
               "a line in column one inside the body");
      Refused ("x: u8 = (" & LF & "f: () -> none = end f" & LF,
               "a hole in a module binding");
      Refused ("f: () -> none =" & LF & "    x := (" & LF & "end f" & LF
               & "x: u8 = (" & LF,
               "one error in a body and one outside it");
      Refused ("f: () -> none = x := 1 + end f" & LF,
               "a body too short to hold the stand-in");
   end Only_A_Body_Is_Stood_In_For;

   --  Past a hole: the names and types of every other routine are
   --  checked, nothing is said inside the body, and no warning is given.
   procedure Analysis_Continues_Past_A_Body
     (Item : in out Landin.Testing.Context);

   procedure Analysis_Continues_Past_A_Body
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
   begin
      Host.Add_File
        ("/w/m.ldn",
         "sum: (x: u8, y: u8) -> (z: u8) =" & LF
         & "    z = x + undefined +" & LF
         & "end sum" & LF
         & LF
         & "twice: (x: u8) -> (y: u8) =" & LF
         & "    mut w := sum (x, x)" & LF
         & "    y = w + true" & LF
         & "end twice" & LF);
      declare
         Answer : constant Landin.Server.Analysis.Result :=
           Analysed (Host, One_File ("/w/m.ldn"));
      begin
         Landin.Testing.Check_Equal
           (Item, Codes_Of (Answer.Found), "L0102, L0301",
            "the body's syntax error, and the type error past it, and"
            & " neither the undefined name inside it nor a warning");
         Landin.Testing.Check
           (Item, Answer.Checked, "the stages ran past syntax");
      end;
   end Analysis_Continues_Past_A_Body;

   --  A broken neighbour needs its stand-in parse, but the sound source's
   --  first tree is transferred to that compilation without a second pass.
   procedure A_Mixed_Module_Parses_Sound_Source_Once
     (Item : in out Landin.Testing.Context);

   procedure A_Mixed_Module_Parses_Sound_Source_Once
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      First_Sound_Passes, Last_Sound_Passes, Broken_Passes : Natural := 0;
      procedure Watch (Name : String);
      procedure Visit
        (Context : in out Landin.Stages.Compilation;
         Answer : Landin.Server.Analysis.Result);

      procedure Watch (Name : String) is
      begin
         if Name = "/w/a.ldn" then
            First_Sound_Passes := First_Sound_Passes + 1;
         elsif Name = "/w/b.ldn" then
            Broken_Passes := Broken_Passes + 1;
         elsif Name = "/w/c.ldn" then
            Last_Sound_Passes := Last_Sound_Passes + 1;
         end if;
      end Watch;

      procedure Visit
        (Context : in out Landin.Stages.Compilation;
         Answer : Landin.Server.Analysis.Result)
      is
         pragma Unreferenced (Context);
      begin
         Landin.Testing.Check
           (Item, Answer.Checked, "mixed module reaches checking");
      end Visit;

      procedure Check_Request
        (Asked : Landin.Server.Analysis.Request; Label : String);

      procedure Check_Request
        (Asked : Landin.Server.Analysis.Request; Label : String) is
      begin
         First_Sound_Passes := 0;
         Last_Sound_Passes := 0;
         Broken_Passes := 0;
         Landin.Server.Analysis.Analyse
           (Landin.Targets.Linux_X86_64,
            Landin.Targets.Levels.Default_Level
              (Landin.Targets.Linux_X86_64),
            Host, Asked, Visit'Access, Watch'Access);
         Landin.Testing.Check_Equal
           (Item, First_Sound_Passes, 1,
            Label & ": first sound source syntax passes");
         Landin.Testing.Check_Equal
           (Item, Last_Sound_Passes, 1,
            Label & ": last sound source syntax passes");
         Landin.Testing.Check_Equal
           (Item, Broken_Passes, 2, Label & ": broken source syntax passes");
      end Check_Request;

      Rooted : Landin.Server.Analysis.Request;
      Named  : Landin.Server.Analysis.Request;
   begin
      Host.Add_Directory ("/w");
      Host.Add_File ("/w/a.ldn", "ready: u8 = 1" & LF);
      Host.Add_File
        ("/w/b.ldn", "sum: (x: u8, y: u8) -> (z: u8) =" & LF
         & "    z = x + y * 3 -" & LF & "end sum" & LF);
      Host.Add_File ("/w/c.ldn", "also_ready: u8 = 2" & LF);
      Rooted.Entry_Directory := Unbounded.To_Unbounded_String ("/w");
      Rooted.Roots := Landin.Platform.Arguments ("/");
      Named.Files.Append ("/w/a.ldn");
      Named.Files.Append ("/w/b.ldn");
      Named.Files.Append ("/w/c.ldn");
      Check_Request (Rooted, "rooted");
      Check_Request (Named, "explicit files");
   end A_Mixed_Module_Parses_Sound_Source_Once;

   ---------------------------------------------------------------------
   --  The corpus
   ---------------------------------------------------------------------

   --  A program the stand-in cannot help is reported as `refine` reports
   --  it, and one that parses is checked as it is: the report is the
   --  driver's, code for code and place for place.
   procedure Analysis_Agrees_With_Refine
     (Item : in out Landin.Testing.Context);

   procedure Analysis_Agrees_With_Refine
     (Item : in out Landin.Testing.Context)
   is
      Real      : aliased Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Compared  : Natural := 0;
   begin
      Fixtures.Discover (Catalogue, Corpus, Real);
      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
            Class : constant Fixtures.Fixture_Class :=
              Fixtures.Class (Fixture);
         begin
            if Class in Fixtures.Positive_Program | Fixtures.Negative_Program
              and then Fixtures.Program (Fixture) /= ""
              and then Fixtures.Args (Fixture) = ""
              and then Fixtures.Targets (Fixture) /= ""
            then
               declare
                  Arguments : Landin.Platform.Path_List;
                  Tools     : Landin.Testing.Fakes.Fake_Tool_Runner;
                  Asked     : Landin.Server.Analysis.Request;
                  Rooted    : Boolean := False;
               begin
                  --  The analysis is linux-x86-64's, and so is refine's
                  --  verdict it is compared with, on every host.
                  Arguments.Append ("--target=linux-x86-64");
                  Fixtures.Append_Module_Arguments
                    (Fixture, Corpus, Arguments);
                  for Argument of Arguments loop
                     if Argument = "--target=linux-x86-64" then
                        null;
                     elsif Argument'Length > 7
                       and then Argument (Argument'First
                                          .. Argument'First + 6) = "--root="
                     then
                        Asked.Roots.Append
                          (Argument (Argument'First + 7 .. Argument'Last));
                        Rooted := True;
                     elsif Rooted then
                        Asked.Entry_Directory :=
                          Unbounded.To_Unbounded_String (Argument);
                     else
                        Asked.Files.Append (Argument);
                     end if;
                  end loop;
                  declare
                     Ran : constant Landin.Driver.Outcome :=
                       Landin.Driver.Execute (Arguments, Real, Tools);
                     Answer : constant Landin.Server.Analysis.Result :=
                       Analysed (Real, Asked);
                     Has_Frontend_Error : Boolean := False;
                  begin
                     for Position in 1 .. Ran.Found.Count loop
                        declare
                           Code : constant String :=
                             Diag.Code (Ran.Found.Get (Position));
                        begin
                           if Code (2 .. 3) = "00" or else Code (2 .. 3) = "01"
                           then
                              Has_Frontend_Error := True;
                           end if;
                        end;
                     end loop;
                     --  A source a stand-in serves says more than refine,
                     --  and the next case holds that one to its own rule.
                     if not Has_Frontend_Error
                       or else not Answer.Checked
                     then
                        Compared := Compared + 1;
                        Landin.Testing.Check_Equal
                          (Item, Codes_Of (Answer.Found),
                           Codes_Of (Diag.Sorted (Ran.Found)),
                           Fixtures.Name (Fixture));
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;
      Landin.Testing.Check
        (Item, Compared > 800,
         "the corpus was compared:" & Natural'Image (Compared));
   end Analysis_Agrees_With_Refine;

   --  Every source the scan or the parse refuses: each negative fixture
   --  whose first code is the frontend's, and each of the fuzzer's
   --  reproducers.  The analysis must raise nothing, report every syntax
   --  error refine reports, in order, and say nothing inside a held body.
   procedure Refused_Sources_Are_Served
     (Item : in out Landin.Testing.Context);

   procedure Refused_Sources_Are_Served
     (Item : in out Landin.Testing.Context)
   is
      Real      : aliased Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Served, Past : Natural := 0;

      function Frontend_Codes (Found : Diag.Diagnostic_List) return String;

      function Frontend_Codes (Found : Diag.Diagnostic_List) return String
      is
         Kept : Diag.Diagnostic_List;
      begin
         for Index in 1 .. Found.Count loop
            if Diag.Code (Found.Get (Index)) (2 .. 3) in "00" | "01" then
               Kept.Append (Found.Get (Index));
            end if;
         end loop;
         return Codes_Of (Kept);
      end Frontend_Codes;

      procedure Serve (Path : String; Label : String);

      procedure Serve (Path : String; Label : String) is
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Ran   : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute
             (Landin.Platform.Arguments (Path), Real, Tools);
      begin
         if Frontend_Codes (Ran.Found) = "" then
            return;
         end if;
         Served := Served + 1;
         declare
            Answer : constant Landin.Server.Analysis.Result :=
              Analysed (Real, One_File (Path));
         begin
            Landin.Testing.Check_Equal
              (Item, Frontend_Codes (Answer.Found),
               Frontend_Codes (Diag.Sorted (Ran.Found)),
               Label & ": every syntax error, in order");
            if Answer.Checked then
               Past := Past + 1;
               for Index in 1 .. Answer.Found.Count loop
                  declare
                     Found : constant Diag.Diagnostic :=
                       Answer.Found.Get (Index);
                  begin
                     if Diag.Code (Found) (2 .. 3) not in "00" | "01"
                       and then Landin.Server.Analysis.Is_Held
                         (Answer, Diag.Source_Of (Diag.Primary (Found)),
                          Diag.Span_Of (Diag.Primary (Found)))
                     then
                        Landin.Testing.Fail
                          (Item, Label & ": a held body is reported on");
                     end if;
                  end;
               end loop;
            end if;
         exception
            when others =>
               Landin.Testing.Fail (Item, Label & ": the analysis raised");
         end;
      end Serve;

      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
   begin
      Fixtures.Discover (Catalogue, Corpus, Real);
      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
         begin
            if Fixtures.Class (Fixture) = Fixtures.Negative_Program
              and then Fixtures.Program (Fixture) /= ""
              and then Fixtures.With_Sources (Fixture) = ""
              and then Fixtures.Module_Root (Fixture) = ""
            then
               Serve
                 (Corpus & "/negative/" & Fixtures.Name (Fixture) & "/"
                  & Fixtures.Program (Fixture),
                  Fixtures.Name (Fixture));
            end if;
         end;
      end loop;
      Real.List_Directory (Reproducers, Entries, Listed);
      for Name of Entries loop
         Serve (Reproducers & "/" & Name, Name);
      end loop;
      Landin.Testing.Check
        (Item, Served >= 60, "every frontend refusal was served");
      Landin.Testing.Check
        (Item, Past > 0, "some were analysed past their holes");
   end Refused_Sources_Are_Served;

   ---------------------------------------------------------------------
   --  Framing
   ---------------------------------------------------------------------

   --  Messages split across reads at every byte, with headers in any case
   --  and order, arrive whole and in order.
   procedure Messages_Arrive_Whole
     (Item : in out Landin.Testing.Context);

   procedure Messages_Arrive_Whole
     (Item : in out Landin.Testing.Context)
   is
      CR_LF : constant String := ASCII.CR & ASCII.LF;
      Input : constant String :=
        Transport.Framed ("{""a"":1}")
        & "content-type: application/vscode-jsonrpc; charset=utf-8" & CR_LF
        & "CONTENT-LENGTH:  3" & CR_LF & "X-Other: ignored" & CR_LF & CR_LF
        & "[1]";
   begin
      for Chunk in 1 .. 7 loop
         declare
            Channel : Landin.Testing.Fakes.Fake_Channel;
            From    : Transport.Reader;
            Outcome : Transport.Status;
            Text, Fault : Unbounded.Unbounded_String;
         begin
            Channel.Script (Input, Chunk);
            Transport.Next (From, Channel, Outcome, Text, Fault);
            Landin.Testing.Check
              (Item, Outcome = Transport.Message
                     and then Unbounded.To_String (Text) = "{""a"":1}",
               "the first message, read" & Chunk'Image & " at a time");
            Transport.Next (From, Channel, Outcome, Text, Fault);
            Landin.Testing.Check
              (Item, Outcome = Transport.Message
                     and then Unbounded.To_String (Text) = "[1]",
               "the second, its headers in any case and order");
            Transport.Next (From, Channel, Outcome, Text, Fault);
            Landin.Testing.Check
              (Item, Outcome = Transport.Ended,
               "and then the end of input");
         end;
      end loop;
   end Messages_Arrive_Whole;

   --  Every way a frame can be wrong, and what each costs.
   procedure Faulty_Frames_Are_Named
     (Item : in out Landin.Testing.Context);

   procedure Faulty_Frames_Are_Named
     (Item : in out Landin.Testing.Context)
   is
      CR_LF : constant String := ASCII.CR & ASCII.LF;

      procedure Expect
        (Input : String; Wanted : Transport.Status; Reason : String);

      procedure Expect
        (Input : String; Wanted : Transport.Status; Reason : String)
      is
         Channel : Landin.Testing.Fakes.Fake_Channel;
         From    : Transport.Reader;
         Outcome : Transport.Status;
         Text, Fault : Unbounded.Unbounded_String;
      begin
         Channel.Script (Input);
         Transport.Next (From, Channel, Outcome, Text, Fault);
         Landin.Testing.Check
           (Item, Outcome = Wanted
                  and then Unbounded.To_String (Fault) = Reason,
            Reason & " (" & Outcome'Image & ": "
            & Unbounded.To_String (Fault) & ")");
      end Expect;
   begin
      Expect ("Content-Length: 5" & CR_LF & CR_LF & "{}",
              Transport.Broken, "the input ended inside a message");
      Expect ("Content-Length: 5" & CR_LF,
              Transport.Broken, "the input ended inside a header");
      Expect ("X: y" & CR_LF & CR_LF & "{}",
              Transport.Broken, "a message has no Content-Length");
      Expect ("Content-Length: -2" & CR_LF & CR_LF,
              Transport.Broken, "Content-Length is not a decimal length");
      Expect ("Content-Length: 99999999999" & CR_LF & CR_LF,
              Transport.Broken, "Content-Length is not a decimal length");
      Expect ("Content-Length: 2" & CR_LF & "Content-Length: 2" & CR_LF
              & CR_LF & "{}",
              Transport.Broken, "Content-Length is given twice");
      Expect ("Content-Length 2" & CR_LF & CR_LF & "{}",
              Transport.Broken, "a header line has no ':'");
      Expect ("Content-Length: 2" & CR_LF & "Content-Type: text/plain"
              & CR_LF & CR_LF & "{}",
              Transport.Broken, "Content-Type is not JSON-RPC in UTF-8");
      Expect ([1 .. Transport.Maximum_Header + 8 => 'x'],
              Transport.Broken, "a header block is longer than 4096 bytes");
      Expect ("", Transport.Ended, "");

      --  A body too long to hold is read past, and the next one is read.
      declare
         Huge : constant Natural := Transport.Maximum_Body + 1;
         Channel : Landin.Testing.Fakes.Fake_Channel;
         From    : Transport.Reader;
         Outcome : Transport.Status;
         Text, Fault : Unbounded.Unbounded_String;
         Input : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String
             ("Content-Length:" & Huge'Image & CR_LF & CR_LF);
      begin
         Unbounded.Append (Input, Unbounded."*" (Huge, ' '));
         Unbounded.Append (Input, Transport.Framed ("{}"));
         Channel.Script_Unbounded (Input, Chunk => 1024 * 1024);
         Transport.Next (From, Channel, Outcome, Text, Fault);
         Landin.Testing.Check
           (Item, Outcome = Transport.Too_Long, "a body past the bound");
         Transport.Next (From, Channel, Outcome, Text, Fault);
         Landin.Testing.Check
           (Item, Outcome = Transport.Message
                  and then Unbounded.To_String (Text) = "{}",
            "is skipped, and the next message read");
      end;
   end Faulty_Frames_Are_Named;

   ---------------------------------------------------------------------
   --  Positions
   ---------------------------------------------------------------------

   procedure Positions_Count_What_Was_Agreed
     (Item : in out Landin.Testing.Context);

   procedure Positions_Count_What_Was_Agreed
     (Item : in out Landin.Testing.Context)
   is
      package P renames Landin.Server.Positions;

      E_Acute : constant String :=
        Character'Val (16#C3#) & Character'Val (16#A9#);
      Clef : constant String :=
        Character'Val (16#F0#) & Character'Val (16#9D#)
        & Character'Val (16#84#) & Character'Val (16#9E#);
      Invalid : constant String := [1 => Character'Val (16#FF#)];
      --  Lines: "a" CR LF, E_Acute Clef Invalid "z" CR, "q" LF, "" (end)
      Text : constant String :=
        "a" & ASCII.CR & ASCII.LF & E_Acute & Clef & Invalid & "z"
        & ASCII.CR & "q" & ASCII.LF;

      procedure Both
        (Offset : Natural; Line, U8, U16 : Natural; Label : String);

      procedure Both
        (Offset : Natural; Line, U8, U16 : Natural; Label : String)
      is
         At_Byte : constant Landin.Source.Byte_Offset :=
           Landin.Source.Byte_Offset (Offset);
         Eight   : constant P.Position :=
           P.Position_Of (Text, At_Byte, P.UTF_8);
         Sixteen : constant P.Position :=
           P.Position_Of (Text, At_Byte, P.UTF_16);
      begin
         Landin.Testing.Check
           (Item, Eight = (Line, U8) and then Sixteen = (Line, U16),
            Label & ": to a position");
         Landin.Testing.Check
           (Item, P.Offset_Of (Text, (Line, U8), P.UTF_8) = At_Byte
                  and then P.Offset_Of (Text, (Line, U16), P.UTF_16)
                             = At_Byte,
            Label & ": and back");
      end Both;
   begin
      Both (0, 0, 0, 0, "the first byte");
      Both (1, 0, 1, 1, "before CR LF");
      Both (3, 1, 0, 0, "after CR LF");
      Both (5, 1, 2, 1, "after a two-byte character");
      Both (9, 1, 6, 3, "after a surrogate pair");
      Both (10, 1, 7, 4, "after an invalid byte, one unit");
      Both (12, 2, 0, 0, "after a lone CR");
      Both (14, 3, 0, 0, "the end of a file ending in a line end");
      Landin.Testing.Check
        (Item, P.Offset_Of (Text, (1, 2), P.UTF_16) = 5,
         "a unit inside a surrogate pair is the pair's first byte");
      Landin.Testing.Check
        (Item, P.Offset_Of (Text, (0, 40), P.UTF_16) = 1,
         "a position past its line is the line's end");
      Landin.Testing.Check
        (Item, P.Offset_Of (Text, (9, 0), P.UTF_16) = 14,
         "a line past the text is its end");
      Landin.Testing.Check
        (Item, P.Position_Of ("ab", 2, P.UTF_16) = (0, 2),
         "the end of a file with no final line end");
      for Unit in P.Encoding loop
         declare
            Map : P.Position_Map;
         begin
            Landin.Testing.Check
              (Item, not P.Ready (Map), "an unprepared map is empty");
            for Offset in reverse 0 .. Text'Length - 1 loop
               P.Register (Map, Landin.Source.Byte_Offset (Offset));
            end loop;
            P.Prepare (Map, Text (Text'First + 1 .. Text'Last), Unit);
            for Offset in 0 .. Text'Length - 1 loop
               Landin.Testing.Check
                 (Item,
                  P.Position_Of
                    (Map, Landin.Source.Byte_Offset (Offset)) =
                  P.Position_Of
                    (Text (Text'First + 1 .. Text'Last),
                     Landin.Source.Byte_Offset (Offset), Unit),
                  "every byte boundary matches the scalar conversion");
            end loop;
            for Offset in 0 .. Text'Length loop
               P.Register (Map, Landin.Source.Byte_Offset (Offset));
            end loop;
            P.Prepare (Map, Text, Unit);
            for Offset in 0 .. Text'Length loop
               Landin.Testing.Check
                 (Item,
                  P.Position_Of
                    (Map, Landin.Source.Byte_Offset (Offset)) =
                  P.Position_Of
                    (Text, Landin.Source.Byte_Offset (Offset), Unit),
                  "every endpoint matches after rebuilding the map");
            end loop;
            P.Register (Map, 100);
            P.Prepare (Map, Text, Unit);
            Landin.Testing.Check
              (Item,
               P.Position_Of (Map, 100) =
               P.Position_Of (Text, 100, Unit),
               "an offset past the text clamps to its end");
            declare
               Empty : P.Position_Map;
            begin
               P.Register (Empty, 0);
               P.Prepare (Empty, "", Unit);
               Landin.Testing.Check
                 (Item, P.Ready (Empty)
                        and then P.Position_Of (Empty, 0) = (0, 0),
                  "the empty text has one position");
            end;
         end;
      end loop;
      declare
         --  The long line makes a byte-indexed map costly even with only
         --  two reported endpoints.
         Long_Text : constant String := [1 .. 4 * 1024 * 1024 => 'x'];
         Map : P.Position_Map;
      begin
         P.Register (Map, 1);
         P.Register (Map, Landin.Source.Byte_Offset (Long_Text'Length));
         P.Prepare (Map, Long_Text, P.UTF_16);
         Landin.Testing.Check
           (Item, P.Endpoint_Count (Map) = 2,
            "a large source stores only its requested endpoints");
         Landin.Testing.Check
           (Item, P.Position_Of (Map, 1) = (0, 1)
                  and then P.Position_Of
                    (Map, Landin.Source.Byte_Offset (Long_Text'Length)) =
                    (0, Long_Text'Length),
            "the long line's endpoints keep their columns");
      end;
   end Positions_Count_What_Was_Agreed;

   ---------------------------------------------------------------------
   --  Sessions
   ---------------------------------------------------------------------

   Sessions_Root : constant String := "../tests/server";

   --  Add the previously absent directory after the first report, before
   --  the editor opens its source.
   procedure Opening_A_Missing_Import_Refreshes_Its_Importer
     (Item : in out Landin.Testing.Context);

   procedure Opening_A_Missing_Import_Refreshes_Its_Importer
     (Item : in out Landin.Testing.Context)
   is
      Host : aliased Landin.Testing.Fakes.Fake_Filesystem;
      type Opening_Channel is new Landin.Testing.Fakes.Fake_Channel
      with record
         Files : access Landin.Testing.Fakes.Fake_Filesystem;
         Created : Boolean := False;
      end record;

      overriding procedure Read
        (Channel : in out Opening_Channel;
         Into : out String;
         Last : out Natural);

      overriding procedure Read
        (Channel : in out Opening_Channel;
         Into : out String;
         Last : out Natural)
      is
      begin
         if not Channel.Created
           and then Ada.Strings.Fixed.Index
             (Landin.Testing.Fakes.Output
                (Landin.Testing.Fakes.Fake_Channel (Channel)),
              """code"":""L0006""") > 0
         then
            Channel.Files.Add_Directory ("/workspace/lib");
            Channel.Files.Add_Directory ("/workspace/lib/numbers");
            Channel.Files.Add_File
              ("/workspace/lib/numbers/numbers.ldn", "");
            Channel.Created := True;
         end if;
         Landin.Testing.Fakes.Read
           (Landin.Testing.Fakes.Fake_Channel (Channel), Into, Last);
      end Read;

      Channel : Opening_Channel := (Landin.Testing.Fakes.Fake_Channel
        with Files => Host'Access, Created => False);
      Script : Unbounded.Unbounded_String;
      Status : Landin.Server.Sessions.Exit_Status;
      Main_URI : constant String := "file:///workspace/app/main.ldn";
      Import_URI : constant String :=
        "file:///workspace/lib/numbers/numbers.ldn";

      procedure Send (Message : String);

      procedure Send (Message : String) is
      begin
         Unbounded.Append (Script, Transport.Framed (Message));
      end Send;
   begin
      Host.Add_Directory ("/workspace");
      Host.Add_Directory ("/workspace/app");
      Host.Add_File ("/workspace/app/main.ldn", "import lib/numbers" & LF);

      Send ("{""jsonrpc"":""2.0"",""id"":1,""method"":""initialize"","
            & """params"":{""capabilities"":{},""initializationOptions"":"
            & "{""roots"":[""file:///workspace""]}}}");
      Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didOpen"","
            & """params"":{""textDocument"":{""uri"":"
            & Landin.Json.Quoted (Main_URI)
            & ",""version"":1,""text"":"
            & Landin.Json.Quoted ("import lib/numbers" & LF) & "}}}");
      Channel.Pause_At
        (Unbounded.Length (Script));
      Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didOpen"","
            & """params"":{""textDocument"":{""uri"":"
            & Landin.Json.Quoted (Import_URI)
            & ",""version"":1,""text"":""""}}}");
      Send ("{""jsonrpc"":""2.0"",""id"":2,""method"":""shutdown""}");
      Send ("{""jsonrpc"":""2.0"",""method"":""exit""}");
      Channel.Script_Unbounded (Script);
      Landin.Server.Sessions.Serve (Channel, Host'Access, Status);
      declare
         Output : constant String :=
           Landin.Testing.Fakes.Output
             (Landin.Testing.Fakes.Fake_Channel (Channel));
      begin
         Landin.Testing.Check
           (Item, Status = 0 and then Channel.Created
            and then Ada.Strings.Fixed.Count
              (Output, """uri"":" & Landin.Json.Quoted (Main_URI)
                       & ",""version"":1") = 2
            and then Ada.Strings.Fixed.Count
              (Output, """code"":""L0006""") = 1,
            "opening a missing import republishes the importer without L0006: "
            & Output);
      end;
   end Opening_A_Missing_Import_Refreshes_Its_Importer;

   procedure Root_URIs_Accept_Trailing_Slashes
     (Item : in out Landin.Testing.Context);

   procedure Root_URIs_Accept_Trailing_Slashes
     (Item : in out Landin.Testing.Context)
   is
      package Documents renames Landin.Server.Documents;
   begin
      Landin.Testing.Check_Equal
        (Item, Documents.Root_Path_Of ("file:///workspace"),
         "/workspace", "root without trailing slash");
      Landin.Testing.Check_Equal
        (Item, Documents.Root_Path_Of ("file:///workspace/"),
         "/workspace", "root with trailing slash");
      Landin.Testing.Check_Equal
        (Item, Documents.Root_Path_Of ("file:///workspace%2F"),
         "/workspace", "root with encoded trailing slash");
      Landin.Testing.Check_Equal
        (Item, Documents.Root_Path_Of ("file:///workspace//"),
         "/workspace", "root with repeated trailing slashes");
      Landin.Testing.Check_Equal
        (Item, Documents.Root_Path_Of ("file:///"),
         "/", "filesystem root");
      Landin.Testing.Check_Equal
        (Item, Documents.Path_Of ("file:///workspace/"),
         "", "a folder URI is not a document path");
      Landin.Testing.Check_Equal
        (Item, Documents.Root_Path_Of ("file:///workspace/../"),
         "", "a parent segment is still refused");
   end Root_URIs_Accept_Trailing_Slashes;

   --  Every session under compiler/tests/server runs as its transcript
   --  says, read through the real filesystem, which is this case's
   --  deliberate exception; the server itself sees only the fake.
   procedure Every_Session_Runs_As_Written
     (Item : in out Landin.Testing.Context);

   procedure Every_Session_Runs_As_Written
     (Item : in out Landin.Testing.Context)
   is
      Real    : Landin.Platform.Native.Native_Filesystem;
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
      Ran     : Natural := 0;
   begin
      Real.List_Directory (Sessions_Root, Entries, Listed);
      for Name of Entries loop
         if Real.Exists (Sessions_Root & "/" & Name & "/session.lsp") then
            declare
               Result : constant Landin.Testing.Sessions.Outcome :=
                 Landin.Testing.Sessions.Run (Sessions_Root & "/" & Name);
            begin
               Ran := Ran + 1;
               Landin.Testing.Check_Equal
                 (Item, Unbounded.To_String (Result.Problem), "", Name);
            end;
         end if;
      end loop;
      Landin.Testing.Check (Item, Ran > 0, "the sessions were found");
   end Every_Session_Runs_As_Written;

   --  The same analyses are needed for diagnostics whether or not
   --  navigation follows them.  No query should repeat one.
   procedure Navigation_Reuses_Checked_Modules
     (Item : in out Landin.Testing.Context);

   procedure Navigation_Reuses_Checked_Modules
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Index in 1 .. 3 loop
         declare
            Name : constant String :=
              (if Index = 1 then "hover"
               elsif Index = 2 then "code-actions"
               else "navigation-past-a-hole");
            Directory : constant String :=
              Sessions_Root & "/" & Name;
            With_Queries : constant Landin.Testing.Sessions.Outcome :=
              Landin.Testing.Sessions.Run (Directory);
            Without_Queries : constant Landin.Testing.Sessions.Outcome :=
              Landin.Testing.Sessions.Run
                (Directory, Include_Navigation => False);
         begin
            Landin.Testing.Check_Equal
              (Item, Unbounded.To_String (With_Queries.Problem), "", Name);
            Landin.Testing.Check (Item, Without_Queries.Analyses > 0,
                                  Name & " analyses its source");
            Landin.Testing.Check
              (Item, With_Queries.Analyses = Without_Queries.Analyses,
               Name & " queries cause no additional analyses");
            if Index = 3 then
               Landin.Testing.Check_Equal
                 (Item, With_Queries.Analyses, 1,
                  "one cached stand-in serves all later navigation");
            end if;
         end;
      end loop;
   end Navigation_Reuses_Checked_Modules;

   procedure Record_Sessions (Wrote : out Boolean) is
      Real    : Landin.Platform.Native.Native_Filesystem;
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
   begin
      Wrote := True;
      Real.List_Directory (Sessions_Root, Entries, Listed);
      for Name of Entries loop
         declare
            Path : constant String :=
              Sessions_Root & "/" & Name & "/session.lsp";
         begin
            if Real.Exists (Path) then
               declare
                  Result : constant Landin.Testing.Sessions.Outcome :=
                    Landin.Testing.Sessions.Run (Sessions_Root & "/" & Name);
                  Status : Landin.Platform.Write_Status;
               begin
                  Real.Write_File
                    (Path, Unbounded.To_String (Result.Recorded), Status);
                  Wrote := Wrote and then Status = Landin.Platform.Write_Ok;
               end;
            end if;
         end;
      end loop;
   end Record_Sessions;

   --  [2000]: the run of `---` lines directly above a declaration's line,
   --  read top to bottom, each without its `---` and one blank after it.
   procedure Doc_Comments_Are_The_Run_Above
     (Item : in out Landin.Testing.Context);

   procedure Doc_Comments_Are_The_Run_Above
     (Item : in out Landin.Testing.Context)
   is
      package N renames Landin.Server.Navigation;

      function Doc (Text : String) return String;

      function Doc (Text : String) return String is
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Spaces  : Landin.Tokens.Spacing.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Id      : constant Landin.Source.Source_Id :=
           Sources.Add ("doc-comment-test", Text);
      begin
         Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
         Landin.Tokens.Spacing.Add (Spaces, Stream);
         return N.Doc_Comment
           (Text, Landin.Source.Byte_Offset
              (Ada.Strings.Fixed.Index (Text, "f:") - Text'First),
            Spaces, Id);
      end Doc;
   begin
      Landin.Testing.Check_Equal
        (Item, Doc ("--- one" & LF & "---two" & LF & "f: u8 = 0" & LF),
         "one" & LF & "two", "a run of two lines, the blank once removed");
      Landin.Testing.Check_Equal
        (Item, Doc ("--- a" & ASCII.CR & ASCII.LF & "  --- b" & ASCII.CR
                    & "    f: u8 = 0" & LF),
         "a" & LF & "b", "over CR LF and lone CR, indented");
      Landin.Testing.Check_Equal
        (Item, Doc ("--- gone" & LF & LF & "f: u8 = 0" & LF), "",
         "a blank line ends the run");
      Landin.Testing.Check_Equal
        (Item, Doc ("--- gone" & LF & "-- line" & LF & "f: u8 = 0" & LF),
         "", "a line comment ends the run");
      Landin.Testing.Check_Equal
        (Item, Doc ("--- kept" & LF & "--( block )--" & LF & "f: u8 = 0"),
         "", "a block comment ends it too");
      Landin.Testing.Check_Equal
        (Item, Doc ("--(" & LF & "--- not documentation )--" & LF
                    & "f: u8 = 0"),
         "", "a doc-looking line inside a block comment is not a doc");
      Landin.Testing.Check_Equal
        (Item, Doc ("--(" & LF & "--- not documentation )--" & LF
                    & "--- real documentation" & LF & "f: u8 = 0"),
         "real documentation", "a doc after a block comment still attaches");
      Landin.Testing.Check_Equal
        (Item, Doc ("x: u8 = 0 --- trailing" & LF & "f: u8 = 0" & LF), "",
         "a doc comment after code is about nothing");
      Landin.Testing.Check_Equal
        (Item, Doc ("f: u8 = 0" & LF), "", "no comment at all");
      Landin.Testing.Check_Equal
        (Item, Doc ("---" & LF & "f: u8 = 0" & LF), "",
         "an empty doc comment says nothing");
      Landin.Testing.Check_Equal
        (Item, Doc ("---( lexical doc" & LF & "f: u8 = 0" & LF),
         "( lexical doc", "a parenthesis after the opener is doc text");
   end Doc_Comments_Are_The_Run_Above;

   --  A source refused before the checker ran has no names or types, so
   --  every query of it answers nothing.  The fuzz lane found a definition
   --  asked of a module whose resolution had been refused raising instead.
   procedure Queries_Of_A_Refused_Module_Answer_Nothing
     (Item : in out Landin.Testing.Context);

   procedure Cursor_Lookup_Keeps_The_Post_Order_Choice
     (Item : in out Landin.Testing.Context);

   procedure Cursor_Lookup_Keeps_The_Post_Order_Choice
     (Item : in out Landin.Testing.Context)
   is
      package Syn renames Landin.Syntax;
      use type Syn.Node_Id;

      Text : constant String :=
        "f: (x: u8) -> (y: u8) =" & LF
        & "    y = x" & LF
        & "end f" & LF
        & "g: () -> (z: u8) =" & LF
        & "    z = f (2)" & LF
        & "end g" & LF
        & "missing, denied: atom" & LF
        & "problems: type = missing | denied" & LF
        & "fallible: (x: u8) -> (y: u8) ! problems =" & LF
        & "    fail missing when x == 0" & LF
        & "    y = x" & LF
        & "end fallible" & LF
        & "h: () -> (v: u8) =" & LF
        & "    v = fallible (1) else 0" & LF
        & "end h" & LF;
      Host : Landin.Testing.Fakes.Fake_Filesystem;
   begin
      Host.Add_File ("/w/m.ldn", Text);
      declare
         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer : Landin.Server.Analysis.Result);

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer : Landin.Server.Analysis.Result)
         is
         begin
            Landin.Testing.Check (Item, Answer.Checked, "source is checked");
            declare
               Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of
                   (Landin.Stages.Trees (Context).all, 1);
            begin
               for Offset in Landin.Source.Byte_Offset range 0 .. Text'Length
               loop
                  declare
                     Expected : Syn.Node_Id := Syn.No_Node;
                     Length   : Landin.Source.Byte_Offset :=
                       Landin.Source.Byte_Offset'Last;
                  begin
                     for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Tree.all)
                     loop
                        declare
                           Where : constant Landin.Source.Span :=
                             Syn.Where (Tree.all, Node);
                        begin
                           if Offset >= Where.First
                             and then Offset < Where.Last
                             and then Where.Last - Where.First < Length
                             and then not Syn.Is_Error
                               (Syn.Kind (Tree.all, Node))
                           then
                              Expected := Node;
                              Length := Where.Last - Where.First;
                           end if;
                        end;
                     end loop;
                     Landin.Testing.Check
                       (Item, Landin.Server.Navigation.Node_At
                                (Tree.all, Offset) = Expected,
                        "same node at byte" & Offset'Image);
                  end;
               end loop;
            end;
         end Visit;
      begin
         Landin.Server.Analysis.Analyse
           (Landin.Targets.Linux_X86_64,
            Landin.Targets.Levels.Default_Level
              (Landin.Targets.Linux_X86_64),
            Host, One_File ("/w/m.ldn"), Visit'Access);
      end;
   end Cursor_Lookup_Keeps_The_Post_Order_Choice;

   procedure Queries_Of_A_Refused_Module_Answer_Nothing
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
   begin
      Host.Add_File
        ("/w/m.ldn", "f: () -> none = g () end f" & LF
                     & "f: () -> none = g () end f" & LF);
      declare
         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result);

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result)
         is
         begin
            Landin.Testing.Check
              (Item, not Answer.Checked and then Answer.Found.Count > 0,
               "a module resolution refuses is not checked");
            for Offset in Landin.Source.Byte_Offset range 0 .. 50 loop
               Landin.Testing.Check
                 (Item, Landin.Server.Navigation.Definition
                          (Context, Answer, 1, Offset)
                        = Landin.Server.Navigation.No_Place
                        and then Landin.Server.Navigation.Hover
                          (Context, Answer, 1, Offset).Length = 0,
                  "nothing is answered at" & Offset'Image);
            end loop;
         end Visit;
      begin
         Landin.Server.Analysis.Analyse
           (Landin.Targets.Linux_X86_64,
            Landin.Targets.Levels.Default_Level
              (Landin.Targets.Linux_X86_64),
            Host, One_File ("/w/m.ldn"), Visit'Access);
      end;
   end Queries_Of_A_Refused_Module_Answer_Nothing;

   procedure An_Unresolved_Name_Leaves_Other_Navigation
     (Item : in out Landin.Testing.Context);

   procedure An_Unresolved_Name_Leaves_Other_Navigation
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Text : constant String :=
        "bad: () -> none = missing () end bad" & LF
        & "good: (x: u8) -> (y: u8) = y = x + 1 end good" & LF;
      Missing : constant Landin.Source.Byte_Offset :=
        Landin.Source.Byte_Offset
          (Ada.Strings.Fixed.Index (Text, "missing") - Text'First);
      Parameter : constant Landin.Source.Byte_Offset :=
        Landin.Source.Byte_Offset
          (Ada.Strings.Fixed.Index (Text, "x: u8") - Text'First);
      Reference : constant Landin.Source.Byte_Offset :=
        Landin.Source.Byte_Offset
          (Ada.Strings.Fixed.Index (Text, "x + 1") - Text'First);
      Expression : constant Landin.Source.Byte_Offset := Reference + 2;
   begin
      Host.Add_File ("/w/m.ldn", Text);
      declare
         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer : Landin.Server.Analysis.Result);

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer : Landin.Server.Analysis.Result)
         is
         begin
            Landin.Testing.Check
              (Item, Answer.Resolved and then Answer.Checked
                     and then Answer.Found.Count > 0,
               "the name error leaves both tables available");
            Landin.Testing.Check_Equal
              (Item, Codes_Of (Answer.Found), "L0201",
               "only the original resolution error is published");
            Landin.Testing.Check
              (Item, Landin.Server.Navigation.Definition
                       (Context, Answer, 1, Missing)
                     = Landin.Server.Navigation.No_Place,
               "the missing name has no definition");
            Landin.Testing.Check
              (Item, Landin.Server.Navigation.Hover
                       (Context, Answer, 1, Missing).Length = 0,
               "the missing name has no hover");
            Landin.Testing.Check
              (Item, Landin.Server.Navigation.Definition
                       (Context, Answer, 1, Reference)
                     = (1, (Parameter, Parameter + 1)),
               "the unrelated parameter still has a definition");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                       (Landin.Server.Navigation.Hover
                          (Context, Answer, 1, Reference).Text,
                        "x: u8") > 0,
               "the unrelated parameter still has a hover");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                       (Landin.Server.Navigation.Hover
                          (Context, Answer, 1, Expression).Text,
                        "u8") > 0,
               "the unrelated expression still has a type");
         end Visit;
      begin
         Landin.Server.Analysis.Analyse
           (Landin.Targets.Linux_X86_64,
            Landin.Targets.Levels.Default_Level
              (Landin.Targets.Linux_X86_64),
            Host, One_File ("/w/m.ldn"), Visit'Access);
      end;
   end An_Unresolved_Name_Leaves_Other_Navigation;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "server", "a broken body is stood in for",
         A_Broken_Body_Is_Stood_In_For'Access);
      Landin.Testing.Register
        (Into, "server", "several broken bodies are stood in for",
         Several_Broken_Bodies_Are_Stood_In_For'Access);
      Landin.Testing.Register
        (Into, "server", "only a body is stood in for",
         Only_A_Body_Is_Stood_In_For'Access);
      Landin.Testing.Register
        (Into, "server", "analysis continues past a body",
         Analysis_Continues_Past_A_Body'Access);
      Landin.Testing.Register
        (Into, "server", "a mixed module parses sound source once",
         A_Mixed_Module_Parses_Sound_Source_Once'Access);
      Landin.Testing.Register
        (Into, "server", "analysis agrees with refine",
         Analysis_Agrees_With_Refine'Access);
      Landin.Testing.Register
        (Into, "server", "refused sources are served",
         Refused_Sources_Are_Served'Access);
      Landin.Testing.Register
        (Into, "server", "messages arrive whole",
         Messages_Arrive_Whole'Access);
      Landin.Testing.Register
        (Into, "server", "faulty frames are named",
         Faulty_Frames_Are_Named'Access);
      Landin.Testing.Register
        (Into, "server", "positions count what was agreed",
         Positions_Count_What_Was_Agreed'Access);
      Landin.Testing.Register
        (Into, "server", "every session runs as written",
         Every_Session_Runs_As_Written'Access);
      Landin.Testing.Register
        (Into, "server", "opening a missing import refreshes its importer",
         Opening_A_Missing_Import_Refreshes_Its_Importer'Access);
      Landin.Testing.Register
        (Into, "server", "root URIs accept trailing slashes",
         Root_URIs_Accept_Trailing_Slashes'Access);
      Landin.Testing.Register
        (Into, "server", "navigation reuses checked modules",
         Navigation_Reuses_Checked_Modules'Access);
      Landin.Testing.Register
        (Into, "server", "doc comments are the run above",
         Doc_Comments_Are_The_Run_Above'Access);
      Landin.Testing.Register
        (Into, "server", "queries of a refused module answer nothing",
         Queries_Of_A_Refused_Module_Answer_Nothing'Access);
      Landin.Testing.Register
        (Into, "server", "cursor lookup keeps the post order choice",
         Cursor_Lookup_Keeps_The_Post_Order_Choice'Access);
      Landin.Testing.Register
        (Into, "server", "an unresolved name leaves other navigation",
         An_Unresolved_Name_Leaves_Other_Navigation'Access);
   end Register;

end Landin.Tests.Server_Suite;
