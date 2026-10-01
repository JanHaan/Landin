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
with Landin.Server.Holes;
with Landin.Server.Navigation;
with Landin.Server.Positions;
with Landin.Server.Transport;
with Landin.Source;
with Landin.Stages;
with Landin.Targets;
with Landin.Testing.Fakes;
with Landin.Testing.Sessions;
with Landin.Testing.Fixtures;

package body Landin.Tests.Server_Suite is

   package Diag renames Landin.Diagnostics;
   package Fixtures renames Landin.Testing.Fixtures;
   package Holes renames Landin.Server.Holes;
   package Transport renames Landin.Server.Transport;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Holes.Verdict;
   use type Transport.Status;
   use type Landin.Server.Positions.Position;
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
      Context : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Answer  : Landin.Server.Analysis.Result;
   begin
      Landin.Server.Analysis.Analyse (Context, Host, Asked, Answer);
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
                  Fixtures.Append_Module_Arguments
                    (Fixture, Corpus, Arguments);
                  for Argument of Arguments loop
                     if Argument'Length > 7
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
   end Positions_Count_What_Was_Agreed;

   ---------------------------------------------------------------------
   --  Sessions
   ---------------------------------------------------------------------

   Sessions_Root : constant String := "../tests/server";

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

      function Doc (Text : String) return String
        is (N.Doc_Comment
              (Text, Landin.Source.Byte_Offset
                 (Ada.Strings.Fixed.Index (Text, "f:") - Text'First)));
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
        (Item, Doc ("x: u8 = 0 --- trailing" & LF & "f: u8 = 0" & LF), "",
         "a doc comment after code is about nothing");
      Landin.Testing.Check_Equal
        (Item, Doc ("f: u8 = 0" & LF), "", "no comment at all");
      Landin.Testing.Check_Equal
        (Item, Doc ("---" & LF & "f: u8 = 0" & LF), "",
         "an empty doc comment says nothing");
   end Doc_Comments_Are_The_Run_Above;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "server", "a broken body is stood in for",
         A_Broken_Body_Is_Stood_In_For'Access);
      Landin.Testing.Register
        (Into, "server", "only a body is stood in for",
         Only_A_Body_Is_Stood_In_For'Access);
      Landin.Testing.Register
        (Into, "server", "analysis continues past a body",
         Analysis_Continues_Past_A_Body'Access);
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
        (Into, "server", "doc comments are the run above",
         Doc_Comments_Are_The_Run_Above'Access);
   end Register;

end Landin.Tests.Server_Suite;
