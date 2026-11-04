with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Build_Identity;
with Landin.Commands;
with Landin.Commands.Catalogue;
with Landin.Driver;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Json;
with Landin.Platform;
with Landin.Testing.Fakes;

package body Landin.Tests.Commands_Suite is
   package US renames Ada.Strings.Unbounded;
   Source : constant String :=
     "public main: () -> (code: i32) = code = 0 end main";
   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) /= 0);

   procedure Help_And_Queries (Item : in out Landin.Testing.Context);
   procedure Help_And_Queries (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Help (Args : Landin.Platform.Path_List);
      procedure Help (Args : Landin.Platform.Path_List) is
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Args, Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal (Item, Result.Status, 0, "help succeeds");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Output),
            Landin.Commands.Catalogue.Usage
              (Landin.Commands.Catalogue.Compile),
            "all help routes describe the compile command");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Output),
                            "firmware targets" & ASCII.LF
                            & "support --debug lines")
              and then Contains (US.To_String (Result.Output),
                                 "Select the firmware entry routine"),
            "compile help describes every firmware target");
      end Help;
   begin
      Host.Raise_On_Read;
      Help (["compile", "--help"]);
      Help (["--help", "compile"]);
      Help (["help", "compile"]);
      declare
         package J renames Landin.Json;
         Machine : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["targets", "--json"], Host, Tools, Meter);
         Human : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (["targets"], Host, Tools, Meter);
         Doc : J.Document;
         Seen_Xtensa : Boolean := False;
      begin
         Landin.Testing.Check
           (Item, Machine.Status = 0 and then Human.Status = 0,
            "both target queries succeed");
         J.Parse (Doc, US.To_String (Machine.Output));
         Landin.Testing.Check
           (Item, J.Ok (Doc), "target query is structured JSON");
         declare
            Rows : constant J.Value :=
              J.Member (Doc, J.Root (Doc), "targets");
         begin
            Landin.Testing.Check_Equal
              (Item, J.Length (Doc, Rows), 10,
               "every described target reports its debug capability");
            for Index in 1 .. J.Length (Doc, Rows) loop
               declare
                  Row : constant J.Value := J.Element (Doc, Rows, Index);
                  Name : constant String :=
                    J.Text (Doc, J.Member (Doc, Row, "name"));
                  Debug : constant J.Value := J.Member (Doc, Row, "debug");
                  Expected : constant String :=
                    (if Name = "synthetic-32" then "none"
                     elsif Name in "cortex-m0" | "rv32" | "xtensa"
                     then "lines" else "full");
               begin
                  Seen_Xtensa := Seen_Xtensa or Name = "xtensa";
                  Landin.Testing.Check
                    (Item, J.Is_Kind (Doc, Debug, J.String_Value),
                     Name & " debug capability is a JSON string");
                  Landin.Testing.Check_Equal
                    (Item, J.Text (Doc, Debug), Expected,
                     Name & " names the supported debug mode");
                  Landin.Testing.Check
                    (Item, Contains (US.To_String (Human.Output),
                       Name
                       & (if Name = "synthetic-32"
                          then " (checking only)" else "") & ": "
                       & J.Text (Doc, J.Member (Doc, Row, "levels"))
                       & "; debug: " & Expected & ASCII.LF),
                     Name & " plain query names the same debug mode");
               end;
            end loop;
         end;
         Landin.Testing.Check
           (Item, Seen_Xtensa, "Xtensa is included in both target queries");
      end;
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (["version", "--json"], Host, Tools, Meter);
         Doc : Landin.Json.Document;
      begin
         Landin.Json.Parse (Doc, US.To_String (Result.Output));
         Landin.Testing.Check (Item, Landin.Json.Ok (Doc),
                               "version query is structured JSON");
      end;
      --  D530: `--full` is explain's own option, before or after what it
      --  is asked about, and the command line hands it to the driver.
      declare
         Before : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["explain", "--full", "D280"], Host, Tools, Meter);
         After : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["explain", "D280", "--full"], Host, Tools, Meter);
         Elsewhere : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["check", "--full", "main.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check
           (Item, Before.Status = 0
                  and then Ada.Strings.Fixed.Index
                    (US.To_String (Before.Output), "Chosen: ") > 0
                  and then US.To_String (After.Output)
                    = US.To_String (Before.Output),
            "explain --full answers wherever --full is written");
         Landin.Testing.Check_Equal
           (Item, Elsewhere.Status, 2, "--full is explain's alone");
      end;
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "informational commands write no files");
      Landin.Testing.Check_Equal
        (Item, Tools.Run_Count, 0, "informational commands invoke no tools");
      Landin.Testing.Check
        (Item, not Landin.Commands.Is_Server (["lsp", "--help"], Host),
         "server help never starts the protocol");
   end Help_And_Queries;

   procedure Version_Identity (Item : in out Landin.Testing.Context);
   procedure Version_Identity (Item : in out Landin.Testing.Context) is
      package BI renames Landin.Build_Identity;
      package J renames Landin.Json;
      use type J.Integer_Value;
      procedure Check_Identity
        (Release_Version, Revision, Source_Digest, Mode : String;
         Dirty : Boolean);
      procedure Check_Identity
        (Release_Version, Revision, Source_Digest, Mode : String;
         Dirty : Boolean)
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Meter : Landin.Platform.Unmetered;
      begin
         Host.Raise_On_Read;
         declare
            Human : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (["version"], Host, Tools, Meter);
            Alias_Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (["--version"], Host, Tools, Meter);
            Machine : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute
                (["version", "--json"], Host, Tools, Meter,
                 Built_For => "test-host");
            Machine_Alias : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute
                (["--version", "--json"], Host, Tools, Meter,
                 Built_For => "test-host");
            Doc : J.Document;
            Expected : US.Unbounded_String :=
              US.To_Unbounded_String ("refine ");
            function Short (Text : String) return String is
              (Text (Text'First .. Text'First + 7));
            Origin : constant String :=
              (if Revision = "unknown" then "source " & Short (Source_Digest)
               else Short (Revision));
            procedure Text_Field (Name, Expected_Text : String);
            procedure Text_Field (Name, Expected_Text : String) is
               Value : constant J.Value := J.Member (Doc, J.Root (Doc), Name);
            begin
               Landin.Testing.Check
                 (Item, J.Is_Kind (Doc, Value, J.String_Value),
                  Name & " is a JSON string");
               if J.Is_Kind (Doc, Value, J.String_Value) then
                  Landin.Testing.Check_Equal
                    (Item, J.Text (Doc, Value), Expected_Text,
                     Name & " is retained");
               end if;
            end Text_Field;
         begin
            US.Append (Expected,
                       (if Release_Version = "" then "dev"
                        else Release_Version));
            if Release_Version = "" or else Dirty then
               US.Append (Expected, " (" & Origin
                          & (if Dirty then ", dirty" else "") & ")");
            end if;
            --  A fake host has no executable directory, so no library.
            US.Append (Expected, ASCII.LF & "library: none" & ASCII.LF);
            Landin.Testing.Check_Equal
              (Item, Human.Status, 0, "version succeeds");
            Landin.Testing.Check_Equal
              (Item, US.To_String (Human.Output), US.To_String (Expected),
               "banner and library lines");
            Landin.Testing.Check_Equal
              (Item, US.To_String (Alias_Result.Output),
               US.To_String (Human.Output),
               "version aliases have identical human output");
            Landin.Testing.Check_Equal
              (Item, US.To_String (Machine_Alias.Output),
               US.To_String (Machine.Output),
               "version aliases have identical JSON");
            J.Parse (Doc, US.To_String (Machine.Output));
            Landin.Testing.Check (Item, J.Ok (Doc), "identity is JSON");
            if J.Ok (Doc) then
               Text_Field ("compiler", "refine");
               Text_Field ("revision", Revision);
               Text_Field ("source_digest", Source_Digest);
               Text_Field ("mode", Mode);
               Text_Field ("host_triplet", "test-host");
               Landin.Testing.Check
                 (Item, J.Is_Kind
                    (Doc, J.Member (Doc, J.Root (Doc), "library"),
                     J.Null_Value), "no library is JSON null");
               if Release_Version = "" then
                  Landin.Testing.Check
                    (Item, J.Is_Kind
                       (Doc, J.Member (Doc, J.Root (Doc), "version"),
                        J.Null_Value), "dev version is JSON null");
               else
                  Text_Field ("version", Release_Version);
               end if;
               Landin.Testing.Check
                 (Item, J.Is_Kind (Doc, J.Member (Doc, J.Root (Doc), "dirty"),
                                  (if Dirty then J.True_Value
                                   else J.False_Value)),
                  "dirty is the recorded Boolean");
               Landin.Testing.Check
                 (Item, J.Is_Integer
                    (Doc, J.Member (Doc, J.Root (Doc), "schema"))
                  and then J.Integer_Of
                    (Doc, J.Member (Doc, J.Root (Doc), "schema")) = 1,
                  "identity retains schema 1");
            end if;
            Landin.Testing.Check_Equal
              (Item, Host.Write_Count, 0, "version writes no files");
            Landin.Testing.Check_Equal
              (Item, Tools.Run_Count, 0, "version invokes no tools");
         end;
      end Check_Identity;
   begin
      Check_Identity
        (BI.Release_Version, BI.Revision, BI.Source_Digest, BI.Mode, BI.Dirty);
   end Version_Identity;

   --  `refine version` says which library a compilation would use: the
   --  one beside the executable, or the one --library names, which must
   --  be one.
   procedure Version_Library (Item : in out Landin.Testing.Context);
   procedure Version_Library (Item : in out Landin.Testing.Context) is
      package J renames Landin.Json;
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      function Last_Line (Text : String) return String;
      function Last_Line (Text : String) return String is
         Ends : constant Natural :=
           (if Text'Length > 0 and then Text (Text'Last) = ASCII.LF
            then Text'Last - 1 else Text'Last);
         Starts : constant Natural := Ada.Strings.Fixed.Index
           (Text (Text'First .. Ends), [ASCII.LF], Ada.Strings.Backward);
      begin
         return Text (Starts + 1 .. Ends);
      end Last_Line;
   begin
      Host.Set_Executable_Directory ("/opt/landin/bin");
      Host.Add_Directory ("/opt/landin/lib/landin/core");
      Host.Add_Directory ("/elsewhere/core");
      Host.Add_Directory ("/empty");
      declare
         Human : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (["version"], Host, Tools, Meter);
         Machine : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (["version", "--json"], Host, Tools, Meter);
         Named : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["version", "--library=/elsewhere"], Host, Tools, Meter);
         Refused : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["version", "--library=/empty"], Host, Tools, Meter);
         Doc : J.Document;
      begin
         Landin.Testing.Check_Equal
           (Item, Last_Line (US.To_String (Human.Output)),
            "library: /opt/landin/lib/landin",
            "the installed library is reported");
         J.Parse (Doc, US.To_String (Machine.Output));
         Landin.Testing.Check
           (Item, J.Ok (Doc)
            and then J.Is_Kind
              (Doc, J.Member (Doc, J.Root (Doc), "library"), J.String_Value)
            and then J.Text (Doc, J.Member (Doc, J.Root (Doc), "library"))
              = "/opt/landin/lib/landin",
            "the installed library is a JSON string");
         Landin.Testing.Check_Equal
           (Item, Last_Line (US.To_String (Named.Output)),
            "library: /elsewhere", "--library replaces it");
         Landin.Testing.Check_Equal
           (Item, Refused.Status, Landin.Driver.Status_Misuse,
            "--library must name a library");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Refused.Report),
                            "--library=/empty holds no core, hosted or"
                            & " platform directory"),
            "the refusal says what is missing: "
            & US.To_String (Refused.Report));
      end;
   end Version_Library;

   procedure Grammar (Item : in out Landin.Testing.Context);
   procedure Grammar (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Misuse (Args : Landin.Platform.Path_List);
      procedure Misuse (Args : Landin.Platform.Path_List) is
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Args, Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 2, "invalid command grammar is misuse");
      end Misuse;
   begin
      Host.Raise_On_Read;
      Misuse (["--target=linux-x86-64", "compile", "a.ldn"]);
      Misuse (["check", "--emit=asm", "a.ldn"]);
      Misuse (["--target=linux-x86-64", "--version"]);
      Misuse (["compile", "--target=linux-x86-64", "--target=linux-arm64"]);
      Misuse (["compile", "--optimize=fast", "a.ldn"]);
      Misuse (["compile", "--firmware-layout=flash", "a.ldn"]);
      Misuse (["compile", "--target=linux-x86-64", "--firmware-layout=ram",
               "a.ldn"]);
      Misuse (["compile", "--firmware-layout=ram", "--firmware-layout=ram",
               "a.ldn"]);
      Misuse (["--quiet", "compile", "--verbose", "a.ldn"]);
      Misuse (["compile", "--output"]);
      Misuse (["build", "--help"]);
      Misuse (["compile", "--depfile="]);
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "misuse writes nothing");
   end Grammar;

   procedure Placement_And_Compatibility
     (Item : in out Landin.Testing.Context);
   procedure Placement_And_Compatibility (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
   begin
      Host.Add_File ("main.ldn", Source);
      declare
         Before : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["--verbose", "check", "--target", "linux-x86-64", "main.ldn"],
            Host, Tools, Meter);
         After : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["check", "--target=linux-x86-64", "main.ldn", "-v"],
            Host, Tools, Meter);
         Legacy : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["--target=linux-x86-64", "main.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal (Item, Before.Status, 0, "check succeeds");
         Landin.Testing.Check_Equal
           (Item, Before.Status, After.Status,
            "shared option placement agrees");
         Landin.Testing.Check_Equal
           (Item, Before.Status, Legacy.Status, "bare sources still check");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Before.Trace), US.To_String (After.Trace),
            "equal requests give equal verbose output");
      end;
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "check produces no artifacts");
   end Placement_And_Compatibility;

   procedure Response_Files (Item : in out Landin.Testing.Context);
   procedure Response_Files (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
   begin
      Host.Add_File ("space name.ldn", Source);
      Host.Add_File
        ("request", "check --target linux-x86-64 'space name.ldn'");
      Host.Add_File ("cycle", "@cycle");
      declare
         Good : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["@request"], Host, Tools, Meter);
         Bad : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["@cycle"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Good.Status, 0, "response quoting retains one spaced path");
         Landin.Testing.Check_Equal (Item, Bad.Status, 2, "cycles are misuse");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Bad.Report), "cycle"),
            "cycle report names the response file");
      end;
      Host.Add_File ("@literal.ldn", Source);
      Host.Add_File ("./-literal.ldn", Source);
      Host.Add_File ("./fmt", Source);
      for Name of Landin.Platform.Path_List'
        (["@literal.ldn", "-literal.ldn", "fmt"])
      loop
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute
                (["check", "--", Name], Host, Tools, Meter);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, 0, "literal sources remain operands");
         end;
      end loop;
   end Response_Files;

   procedure Emission_And_Depfile (Item : in out Landin.Testing.Context);
   procedure Emission_And_Depfile (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Refused (Args : Landin.Platform.Path_List);
      procedure Refused (Args : Landin.Platform.Path_List) is
         Count : constant Natural := Host.Write_Count;
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Args, Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 2, "invalid dependency path is misuse");
         Landin.Testing.Check_Equal
           (Item, Host.Write_Count, Count, "refusal precedes all writes");
      end Refused;
   begin
      Host.Add_File ("main.ldn", Source);
      declare
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc",
             "--emit", "asm",
             "main.ldn", "-o", "out.s", "--depfile", "out.d"],
            Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal (Item, Result.Status, 0, "compile emits");
         Landin.Testing.Check
           (Item, Host.Written ("out.s") /= "", "assembly is written");
         Landin.Testing.Check
           (Item, Contains (Host.Written ("out.d"), "out.s: main.ldn"),
            "depfile connects output to loaded source");
         Landin.Testing.Check_Equal (Item, Tools.Run_Count, 0,
                                     "assembly invokes no external tool");
      end;
      declare
         Count : constant Natural := Host.Write_Count;
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc",
             "--emit=asm", "main.ldn",
             "--depfile=main.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 2,
            "dependency output cannot overwrite source");
         Landin.Testing.Check_Equal
           (Item, Host.Write_Count, Count,
            "collision precedes artifact writes");
      end;
      Refused (["compile", "--emit=asm", "main.ldn", "-o=out.s",
                "--depfile=out.s"]);
      Refused (["compile", "--emit=asm", "main.ldn",
                "--depfile=report.json", "--stage-report=report.json"]);
      Refused (["compile", "--emit=asm", "main.ldn",
                "--depfile=report.json", "--build-report=report.json"]);
      Refused (["compile", "--emit=asm", "main.ldn",
                "-o=out" & ASCII.LF & ".s", "--depfile=out.d"]);
      Host.Add_File ("bad" & ASCII.LF & ".ldn", Source);
      Refused (["compile", "--emit=asm", "bad" & ASCII.LF & ".ldn",
                "--depfile=out.d"]);
   end Emission_And_Depfile;

   procedure Dry_Run (Item : in out Landin.Testing.Context);
   procedure Dry_Run (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
   begin
      Host.Add_File ("main.ldn", Source);
      declare
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc", "--dry-run",
             "main.ldn",
             "--stage-report=stages.json", "--build-report=build.json",
             "--depfile=out.d"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal (Item, Result.Status, 0, "dry run checks");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Output), "run ["),
            "dry run shows the argument vector");
         Landin.Testing.Check_Equal
           (Item, Host.Write_Count, 0, "dry run writes no report or artifact");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "dry run starts no tools");
      end;
      Host.Add_File ("bad.ldn", "@");
      Host.Add_File ("no-main.ldn", "public f: () -> none = end f");
      for Name of Landin.Platform.Path_List'(["bad.ldn", "no-main.ldn"])
      loop
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute
                (["compile", "--dry-run", Name], Host, Tools, Meter);
         begin
            Landin.Testing.Check
              (Item, Result.Status /= 0, "dry run refuses invalid programs");
         end;
      end loop;
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "failed dry runs also write nothing");
      Landin.Testing.Check_Equal
        (Item, Tools.Run_Count, 0, "failed dry runs also start no tools");
   end Dry_Run;

   procedure Presentation (Item : in out Landin.Testing.Context);
   procedure Presentation (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
   begin
      Host.Add_File ("bad.ldn", "@");
      declare
         Short : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["check", "--diagnostics=short", "bad.ldn"], Host, Tools, Meter);
         JSON : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["--diagnostics=json", "check", "bad.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Short.Status, JSON.Status, "presentation preserves refusal");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Short.Report), "bad.ldn:1:1:"),
            "short format names byte coordinates");
         Landin.Testing.Check
           (Item, Contains (US.To_String (JSON.Report), """labels"":"),
            "JSON carries structured diagnostic labels");
         Landin.Testing.Check
           (Item, Contains (US.To_String (JSON.Report), """fixes"":"),
            "JSON retains repairs");
      end;
   end Presentation;

   procedure JSON_Fixes (Item : in out Landin.Testing.Context);
   procedure JSON_Fixes (Item : in out Landin.Testing.Context) is
      package D renames Landin.Diagnostics;
      package J renames Landin.Json;
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Check (Source : String; Status : Natural);
      procedure Check (Source : String; Status : Natural) is
         Result : Landin.Driver.Outcome;
         Cursor : Positive := 1;
      begin
         Host.Add_File ("fix.ldn", Source);
         Result := Landin.Commands.Execute
           (["check", "--diagnostics=json", "fix.ldn"], Host, Tools, Meter);
         Landin.Testing.Check_Equal
           (Item, Result.Status, Status, "JSON preserves source verdict");
         Landin.Testing.Check
           (Item, D.Count (Result.Found) > 0, "source supplies diagnostics");
         for Index in 1 .. D.Count (Result.Found) loop
            declare
               Text : constant String := US.To_String (Result.Report);
               Last : constant Natural :=
                 Ada.Strings.Fixed.Index (Text, "" & ASCII.LF, Cursor);
               Doc : J.Document;
               Expected : constant D.Diagnostic := D.Get (Result.Found, Index);
            begin
               Landin.Testing.Check
                 (Item, Last >= Cursor, "every diagnostic has one JSON line");
               if Last < Cursor then
                  return;
               end if;
               J.Parse (Doc, Text (Cursor .. Last - 1));
               Landin.Testing.Check
                 (Item, J.Ok (Doc), "fix-bearing diagnostics are valid JSON");
               if not J.Ok (Doc) then
                  return;
               end if;
               declare
                  Root : constant J.Value := J.Root (Doc);
                  Labels : constant J.Value := J.Member (Doc, Root, "labels");
                  Notes : constant J.Value := J.Member (Doc, Root, "notes");
                  Fixes : constant J.Value := J.Member (Doc, Root, "fixes");
               begin
                  Landin.Testing.Check_Equal
                    (Item, J.Text (Doc, J.Member (Doc, Root, "code")),
                     D.Code (Expected), "diagnostic order and codes survive");
                  Landin.Testing.Check_Equal
                    (Item, J.Length (Doc, Labels),
                     D.Label_Count (Expected) + 1,
                     "primary and secondary labels survive");
                  Landin.Testing.Check_Equal
                    (Item, J.Length (Doc, Notes), D.Note_Count (Expected),
                     "all notes survive");
                  for Position in 1 .. D.Note_Count (Expected) loop
                     Landin.Testing.Check_Equal
                       (Item, J.Text (Doc, J.Element (Doc, Notes, Position)),
                        D.Nth_Note (Expected, Position), "note bytes survive");
                  end loop;
                  Landin.Testing.Check_Equal
                    (Item, J.Length (Doc, Fixes), D.Fix_Count (Expected),
                     "every alternative fix survives");
                  for Position in 1 .. D.Fix_Count (Expected) loop
                     declare
                        Fix : constant D.Fix := D.Nth_Fix (Expected, Position);
                        Object : constant J.Value :=
                          J.Element (Doc, Fixes, Position);
                        Edits : constant J.Value :=
                          J.Member (Doc, Object, "edits");
                     begin
                        Landin.Testing.Check_Equal
                          (Item, J.Text
                             (Doc, J.Member (Doc, Object, "message")),
                           D.Message (Fix), "fix messages survive");
                        Landin.Testing.Check_Equal
                          (Item, J.Length (Doc, Edits), D.Edit_Count (Fix),
                           "edits are nested under their own fix");
                        for Number in 1 .. D.Edit_Count (Fix) loop
                           declare
                              Edit : constant D.Edit :=
                                D.Nth_Edit (Fix, Number);
                              Value : constant J.Value :=
                                J.Element (Doc, Edits, Number);
                           begin
                              Landin.Testing.Check_Equal
                                (Item, J.Text
                                   (Doc, J.Member (Doc, Value, "replacement")),
                                 D.Replacement (Edit),
                                 "ordered replacement bytes survive");
                           end;
                        end loop;
                     end;
                  end loop;
               end;
               Cursor := Last + 1;
            end;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Cursor, US.Length (Result.Report) + 1,
            "every emitted JSON line was parsed");
      end Check;
   begin
      Check ("public f: () -> (result: i32) =" & ASCII.LF
        & "mut value: i32 = 1" & ASCII.LF
        & "unused: i32 = 42" & ASCII.LF
        & "result = value" & ASCII.LF & "end f" & ASCII.LF, 0);
      Check ("public f: () -> none = value: i32 = 1 value = 2 end f", 1);
      Check ("count: (value: u32) -> (result: u32) = value + 1 end count "
        & "cuona: (value: u32) -> (result: u32) = value + 2 end cuona "
        & "cuons: (value: u32) -> (result: u32) = value + 3 end cuons "
        & "total: (limit: u32) -> (result: u32) = mut sum: u32 = 0 "
        & "while sum < limt do sum = cuont(value: sum) end while "
        & "result = sum end total", 1);
   end JSON_Fixes;

   procedure Warning_Controls (Item : in out Landin.Testing.Context);
   procedure Warning_Controls (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      package D renames Landin.Diagnostics;
      package C renames Landin.Diagnostics.Catalogue;
      use type D.Severity;
      Mutable_Code : constant String := C.Code (C.Mutable_Never_Written);
      Unused_Code : constant String := C.Code (C.Unused_Pure_Local);
      Program : constant String :=
        "public main: () -> (code: i32) =" & ASCII.LF
        & "mut value: i32 = 1" & ASCII.LF
        & "unused: i32 = 42" & ASCII.LF
        & "code = value - 1" & ASCII.LF & "end main" & ASCII.LF;
      procedure Refused (Args : Landin.Platform.Path_List);
      procedure Refused (Args : Landin.Platform.Path_List) is
         Trap : Landin.Testing.Fakes.Fake_Filesystem;
         Result : Landin.Driver.Outcome;
      begin
         Trap.Raise_On_Read;
         Result := Landin.Commands.Execute (Args, Trap, Tools, Meter);
         Landin.Testing.Check_Equal
           (Item, Result.Status, 2, "warning misuse precedes source reads");
      end Refused;
   begin
      Refused (["check", "--warn=" & C.Code (C.Unknown_Option), "missing"]);
      Refused (["check", "--allow=L9999", "missing"]);
      Refused (["check", "--warn=L0001", "missing"]);
      Refused (["check", "--deny=bad", "missing"]);
      Refused (["check", "--warnings=some", "missing"]);
      Refused (["--warn=all", "check", "missing"]);
      Refused (["--warn=all", "missing"]);
      Refused (["fmt", "--warn=all", "missing"]);
      Refused (["lsp", "--warn=all"]);
      Refused (["--identify", "--warn=all"]);
      Host.Add_File ("main.ldn", Program);
      for Path of Landin.Platform.Path_List'
        (["out.s", "out.d", "build.json", "stage.json"])
      loop
         Host.Add_File (Path, "preserved");
      end loop;
      declare
         Count : constant Natural := Host.Write_Count;
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "main.ldn", "-o=out.s",
             "--deny=all", "--depfile=out.d", "--build-report=build.json",
             "--stage-report=stage.json"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 1, "denied warnings refuse compilation");
         Landin.Testing.Check_Equal
           (Item, Host.Write_Count, Count, "denial precedes all writes");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "denial starts no native tools");
         Landin.Testing.Check_Equal
           (Item, D.Count (Result.Found), 2, "both warnings are denied");
         Landin.Testing.Check_Equal
           (Item, D.Code (D.Get (Result.Found, 1)), Mutable_Code,
            "mutable warning caused refusal");
         Landin.Testing.Check_Equal
           (Item, D.Code (D.Get (Result.Found, 2)), Unused_Code,
            "unused warning caused refusal");
         for Index in 1 .. D.Count (Result.Found) loop
            Landin.Testing.Check
              (Item, D.Fix_Count (D.Get (Result.Found, Index)) > 0,
               "promotion preserves exact fixes");
            Landin.Testing.Check
              (Item, D.Level (D.Get (Result.Found, Index)) = D.Error,
               "denied warning severity is error");
            Landin.Testing.Check
              (Item, D.Note_Count (D.Get (Result.Found, Index)) > 0,
               "denied warning retains notes");
         end loop;
      end;
      declare
         Base : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc",
             "--emit=asm", "main.ldn",
             "-o=base.s"], Host, Tools, Meter);
         Allowed : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc",
             "--emit=asm", "main.ldn",
             "-o=allowed.s", "--allow=all"], Host, Tools, Meter);
         Selected : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["check", "main.ldn", "--warn=" & Mutable_Code,
             "--warnings=none", "--deny=all", "--allow=all",
             "--warn=" & Unused_Code], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal (Item, Base.Status, 0, "warnings lawful");
         Landin.Testing.Check_Equal
           (Item, Allowed.Status, 0, "allowed warnings compile");
         Landin.Testing.Check_Equal
           (Item, D.Count (Allowed.Found), 0, "allow filters only warnings");
         Landin.Testing.Check_Equal
           (Item, Host.Written ("base.s"), Host.Written ("allowed.s"),
            "warning selection preserves emitted assembly bytes");
         Landin.Testing.Check_Equal
           (Item, Selected.Status, 0, "last matching directive wins");
         Landin.Testing.Check_Equal
           (Item, D.Count (Selected.Found), 1,
            "only selected warning remains");
         Landin.Testing.Check_Equal
           (Item, D.Code (D.Get (Selected.Found, 1)), Unused_Code,
            "per-code control follows global control");
      end;
      Host.Add_File ("bad.ldn", "@");
      declare
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["check", "bad.ldn", "--warnings=none", "--allow=all"],
            Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 1, "language errors cannot be suppressed");
         Landin.Testing.Check (Item, D.Has_Errors (Result.Found),
                               "language error data survives");
      end;
   end Warning_Controls;

   --  D384: an option written before its command, or
   --  with no command, is refused naming the commands it belongs to and
   --  where it goes, with the option as it was written.
   procedure Options_Before_Their_Command
     (Item : in out Landin.Testing.Context);
   procedure Options_Before_Their_Command
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Refused (Args : Landin.Platform.Path_List; Says : String);
      procedure Refused (Args : Landin.Platform.Path_List; Says : String) is
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Args, Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "a misplaced option is misuse");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Report), Says),
            "the refusal says " & Says & ": "
            & US.To_String (Result.Report));
      end Refused;
   begin
      Host.Raise_On_Read;
      Refused (["--root=lib", "compile", "a.ldn"],
               "--root=lib is an option of check, compile and run, and"
               & " follows its command: refine compile --root=lib ...");
      Refused (["--library", "/opt/lib", "compile", "a.ldn"],
               "--library=/opt/lib is an option of check, compile, run and"
               & " version, and follows its command: refine compile"
               & " --library=/opt/lib ...");
      Refused (["--emit=asm", "check", "a.ldn"],
               "--emit=asm is an option of compile, not of check, and"
               & " follows its command: refine compile --emit=asm ...");
      Refused (["--target=linux-x86-64", "--version"],
               "--target=linux-x86-64 is an option of check, compile, run"
               & " and bindings, not of version");
      Refused (["-o", "x.s", "main.ldn"],
               "-o x.s is an option of compile; name the command first:"
               & " refine compile -o x.s ...");
      Refused (["--library=/opt/lib", "--depfile=d", "main.ldn"],
               "--depfile is an option of compile; name the command first");
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "misuse writes nothing");
   end Options_Before_Their_Command;

   --  D383: check takes the options that say what program is
   --  compiled, a single source file with --root, --firmware-entry,
   --  --link and --build-report among them, and holds them as compile
   --  does without emitting anything.
   procedure Check_Takes_What_Compile_Takes
     (Item : in out Landin.Testing.Context);
   procedure Check_Takes_What_Compile_Takes
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      LF : constant Character := ASCII.LF;
      function Run (Args : Landin.Platform.Path_List)
        return Landin.Driver.Outcome
        is (Landin.Commands.Execute (Args, Host, Tools, Meter));
   begin
      Host.Add_File ("main.ldn", Source);
      Host.Add_File
        ("fw.ldn",
         "public start: () -> noreturn =" & LF & "    loop do" & LF
         & "    end loop" & LF & "end start" & LF);
      Host.Add_Directory ("lib");
      Host.Add_Directory ("lib/shapes");
      Host.Add_File
        ("lib/shapes/shapes.ldn",
         "public side: () -> (length: i32) = length = 2 end side");
      Host.Add_File
        ("rooted.ldn",
         "import shapes" & LF & LF
         & "public main: () -> (code: i32) = code = shapes.side() end main");
      declare
         Rooted : constant Landin.Driver.Outcome :=
           Run (["check", "--target=linux-x86-64", "--root=lib",
                 "rooted.ldn"]);
      begin
         Landin.Testing.Check_Equal
           (Item, Rooted.Status, Landin.Driver.Status_Success,
            "one source file with --root reaches the root's module: "
            & US.To_String (Rooted.Report));
      end;
      declare
         Entered : constant Landin.Driver.Outcome :=
           Run (["check", "--target=cortex-m0", "--firmware-entry=start",
                 "fw.ldn"]);
         Missing : constant Landin.Driver.Outcome :=
           Run (["check", "--target=cortex-m0", "--firmware-entry=absent",
                 "fw.ldn"]);
         Hosted : constant Landin.Driver.Outcome :=
           Run (["check", "--target=linux-x86-64", "--firmware-entry=start",
                 "fw.ldn"]);
      begin
         Landin.Testing.Check_Equal
           (Item, Entered.Status, Landin.Driver.Status_Success,
            "check takes the firmware entry: "
            & US.To_String (Entered.Report));
         Landin.Testing.Check
           (Item, Missing.Status = Landin.Driver.Status_Reported
                  and then Contains (US.To_String (Missing.Report),
                                     "--firmware-entry=absent"),
            "and refuses one that names no entry: "
            & US.To_String (Missing.Report));
         Landin.Testing.Check
           (Item, Hosted.Status = Landin.Driver.Status_Misuse
                  and then Contains (US.To_String (Hosted.Report),
                    "--firmware-entry requires a firmware target:"
                    & " --target=cortex-m0 or --target=rv32"),
            "a hosted target refuses it as compile does");
      end;
      declare
         Libc : constant Landin.Driver.Outcome :=
           Run (["check", "--target=linux-x86-64", "--link=libc",
                 "main.ldn"]);
         Firmware : constant Landin.Driver.Outcome :=
           Run (["check", "--target=cortex-m0", "--link=libc", "fw.ldn"]);
      begin
         Landin.Testing.Check_Equal
           (Item, Libc.Status, Landin.Driver.Status_Success,
            "check takes --link: " & US.To_String (Libc.Report));
         Landin.Testing.Check_Equal
           (Item, Firmware.Status, Landin.Driver.Status_Misuse,
            "and refuses it for a target with no hosted system");
      end;
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "none of these writes anything");
      declare
         Reported : constant Landin.Driver.Outcome :=
           Run (["check", "--target=linux-x86-64",
                 "--build-report=report.json", "main.ldn"]);
         Collides : constant Landin.Driver.Outcome :=
           Run (["check", "--target=linux-x86-64",
                 "--build-report=main.ldn", "main.ldn"]);
      begin
         Landin.Testing.Check_Equal
           (Item, Reported.Status, Landin.Driver.Status_Success,
            "check takes --build-report: "
            & US.To_String (Reported.Report));
         Landin.Testing.Check
           (Item, Contains (Host.Written ("report.json"),
                            """format"":""landin-build-report-1""")
                  and then Contains (Host.Written ("report.json"),
                                     """sources"":[")
                  and then Contains (Host.Written ("report.json"),
                                     """link"":""static"""),
            "and writes what it checked: " & Host.Written ("report.json"));
         Landin.Testing.Check
           (Item, Collides.Status = Landin.Driver.Status_Misuse
                  and then Host.Written ("main.ldn") = "",
            "a report over a source is refused, as compile refuses it");
      end;
   end Check_Takes_What_Compile_Takes;

   Linux_Host : constant String := "x86_64-pc-linux-gnu";

   --  D526: `run` compiles into a private directory, names the program
   --  after its entry, hands it what follows `--` exactly, exits with its
   --  status and removes the directory once it has run.
   procedure Run_Compiles_And_Runs (Item : in out Landin.Testing.Context);
   procedure Run_Compiles_And_Runs (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      Result : Landin.Driver.Outcome;
   begin
      Host.Add_File ("main.ldn", Source);
      Tools.Set_Result (0, "");
      Tools.Set_Program_Result (7);
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "main.ldn", "--", "a", "", "-b", "--",
          "@file"], Host, Tools, Meter, Built_For => Linux_Host);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 0,
         "the program compiles: " & US.To_String (Result.Report));
      Landin.Testing.Check_Equal
        (Item, US.To_String (Result.Launch_Program),
         "/virtual/tmp/refine-run-1/main",
         "the executable is named after its entry, in a private directory");
      Landin.Testing.Check_Equal
        (Item, Landin.Platform.Joined (Result.Launch_Arguments),
         "a" & ASCII.LF & ASCII.LF & "-b" & ASCII.LF & "--" & ASCII.LF
         & "@file" & ASCII.LF,
         "what follows the first -- is the program's, exactly");
      Landin.Testing.Check
        (Item, Tools.Run_Count = 1
           and then (for some Argument of Tools.Call_At (1).Arguments =>
                       Argument = "/virtual/tmp/refine-run-1/main"),
         "the link writes the executable into the directory");
      Landin.Testing.Check
        (Item, Host.Is_Directory ("/virtual/tmp/refine-run-1"),
         "the directory stays until the program has run");
      Landin.Commands.Launch (Result, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 7, "refine exits with the program's status");
      Landin.Testing.Check_Equal
        (Item, US.To_String (Result.Report), "",
         "a program that exits is not described");
      Landin.Testing.Check
        (Item, Tools.Run_Count = 2 and then Tools.Call_At (2).Attached
           and then US.To_String (Tools.Call_At (2).Program)
             = "/virtual/tmp/refine-run-1/main"
           and then Natural (Tools.Call_At (2).Arguments.Length) = 5,
         "the program runs attached, with its arguments");
      Landin.Testing.Check
        (Item, not Host.Exists ("/virtual/tmp/refine-run-1")
           and then not Host.Exists ("/virtual/tmp/refine-run-1/main"),
         "the directory is removed once the program ends");
      Landin.Commands.Launch (Result, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Tools.Run_Count, 2, "a launched outcome runs nothing again");

      Host.Add_File ("./-tool.ldn", Source);
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "./-tool.ldn"], Host, Tools, Meter,
         Built_For => Linux_Host);
      Landin.Testing.Check_Equal
        (Item, US.To_String (Result.Launch_Program),
         "/virtual/tmp/refine-run-2/-tool",
         "a source spelt with a leading hyphen is ./-name.ldn");
   end Run_Compiles_And_Runs;

   --  D526: a program a signal ended is named, with 128 and its number.
   procedure Run_Reports_A_Signal (Item : in out Landin.Testing.Context);
   procedure Run_Reports_A_Signal (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      Result : Landin.Driver.Outcome;
   begin
      Host.Add_File ("game.ldn", Source);
      Tools.Set_Result (0, "");
      Tools.Set_Program_Result (0, Signal => 11, Signal_Name => "SIGSEGV");
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "game.ldn"], Host, Tools, Meter,
         Built_For => Linux_Host);
      Landin.Commands.Launch (Result, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, 139, "128 and the signal's number");
      Landin.Testing.Check_Equal
        (Item, US.To_String (Result.Report),
         "refine: game was ended by SIGSEGV (signal 11)" & ASCII.LF,
         "one line names the signal");
      Landin.Testing.Check
        (Item, not Host.Exists ("/virtual/tmp/refine-run-1"),
         "a killed program's directory is removed");
      --  D730: a termination sent to refine is passed on, and the program
      --  it ends is reported and its directory removed as for any other.
      Tools.Set_Program_Result (0, Signal => 15, Signal_Name => "SIGTERM");
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "game.ldn"], Host, Tools, Meter,
         Built_For => Linux_Host);
      Landin.Commands.Launch (Result, Host, Tools);
      Landin.Testing.Check
        (Item, Result.Status = 143
           and then US.To_String (Result.Report)
             = "refine: game was ended by SIGTERM (signal 15)" & ASCII.LF
           and then not Host.Exists ("/virtual/tmp/refine-run-2"),
         "a program a forwarded termination ended is reported, and its"
         & " directory removed: " & US.To_String (Result.Report));
   end Run_Reports_A_Signal;

   --  D526: the directory goes on every way out before the program runs.
   procedure Run_Removes_Its_Directory
     (Item : in out Landin.Testing.Context);
   procedure Run_Removes_Its_Directory
     (Item : in out Landin.Testing.Context)
   is
      Meter : Landin.Platform.Unmetered;
   begin
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("bad.ldn", "public main: () -> (code: i32) = end");
         Result := Landin.Commands.Execute
           (["run", "--link=libc", "bad.ldn"], Host, Tools, Meter,
            Built_For => Linux_Host);
         Landin.Testing.Check
           (Item, Result.Status = 1
              and then US.Length (Result.Launch_Program) = 0
              and then Host.Private_Directory_Count = 1
              and then not Host.Exists ("/virtual/tmp/refine-run-1")
              and then Tools.Run_Count = 0,
            "a refused program leaves no directory and runs nothing");
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Source);
         Tools.Set_Result (1, "ld: refused" & ASCII.LF);
         Result := Landin.Commands.Execute
           (["run", "--link=libc", "main.ldn"], Host, Tools, Meter,
            Built_For => Linux_Host);
         Landin.Testing.Check
           (Item, Result.Status = 1
              and then Contains (US.To_String (Result.Report), "L0501")
              and then not Host.Exists ("/virtual/tmp/refine-run-1")
              and then Tools.Run_Count = 1,
            "a failed link leaves no directory and runs nothing");
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Source);
         Tools.Set_Result (0, "");
         Result := Landin.Commands.Execute
           (["run", "--link=libc", "main.ldn"], Host, Tools, Meter,
            Built_For => Linux_Host);
         Tools.Raise_On_Run
           (Landin.External_Tool_Failed'Identity,
            "cannot start /virtual/tmp/refine-run-1/main");
         Landin.Commands.Launch (Result, Host, Tools);
         Landin.Testing.Check
           (Item, Result.Status = 1
              and then US.To_String (Result.Report)
                = "refine: cannot start /virtual/tmp/refine-run-1/main"
                  & ASCII.LF
              and then not Host.Exists ("/virtual/tmp/refine-run-1"),
            "a program that cannot start leaves no directory");
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Source);
         Host.Refuse_Private_Directories;
         Result := Landin.Commands.Execute
           (["run", "--link=libc", "main.ldn"], Host, Tools, Meter,
            Built_For => Linux_Host);
         Landin.Testing.Check
           (Item, Result.Status = 1
              and then Contains
                (US.To_String (Result.Report),
                 "cannot make a private directory")
              and then Tools.Run_Count = 0,
            "no directory, nothing compiled");
      end;
   end Run_Removes_Its_Directory;

   --  D565: what an option needs of its request is the catalogue's, so
   --  the commands' parse and the driver refuse one combination with one
   --  sentence, and the catalogue's sentence is what a refusal says.
   procedure Option_Requirements_Are_One
     (Item : in out Landin.Testing.Context);
   procedure Option_Requirements_Are_One
     (Item : in out Landin.Testing.Context)
   is
      package Cat renames Landin.Commands.Catalogue;
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Same
        (Command, Direct : Landin.Platform.Path_List; Expected : String);
      procedure Same
        (Command, Direct : Landin.Platform.Path_List; Expected : String)
      is
         Parsed : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (Command, Host, Tools, Meter, Built_For => Linux_Host);
         Driven : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Direct, Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Parsed.Status = Landin.Driver.Status_Misuse
              and then Driven.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Parsed.Report), Expected)
              and then Contains (US.To_String (Driven.Report), Expected),
            Expected & ": " & US.To_String (Parsed.Report)
            & US.To_String (Driven.Report));
      end Same;
   begin
      Host.Add_File ("main.ldn", Source);
      Same (["compile", "--emit=ir", "--debug=full", "main.ldn"],
            ["--emit=ir", "--debug=full", "main.ldn"],
            Cat.Requirement_Problem (Cat.Debug, Cat.Emit_IR, True));
      Same (["compile", "--target=cortex-m0", "--emit=linker-script",
             "--debug=lines", "main.ldn"],
            ["--target=cortex-m0", "--emit=linker-script", "--debug=lines",
             "main.ldn"],
            Cat.Requirement_Problem
              (Cat.Debug, Cat.Emit_Linker_Script, True));
      Same (["compile", "--emit=asm", "--keep-asm", "main.ldn", "-o", "a.s"],
            ["--emit=asm", "--keep-asm", "main.ldn", "-o", "a.s"],
            Cat.Requirement_Problem (Cat.Keep_Asm, Cat.Emit_Asm, True));
      Same (["compile", "--target=cortex-m0", "--firmware-layout=ram"],
            ["--target=cortex-m0", "--firmware-layout=ram"],
            Cat.Requirement_Problem
              (Cat.Firmware_Layout, Cat.Emit_Exe, False));
      Same (["compile", "--optimize=speed"],
            ["--emit=exe", "--optimize=speed"],
            Cat.Requirement_Problem (Cat.Optimize, Cat.Emit_Exe, False));
      Same (["compile", "--optimize=fast", "main.ldn"],
            ["--optimize=fast", "main.ldn"],
            "--optimize does not take `fast`; it takes none, size or speed");
      Same (["compile", "--target=linux-x86-64", "--target=linux-arm64",
             "main.ldn"],
            ["--target=linux-x86-64", "--target=linux-arm64", "main.ldn"],
            Cat.Given_Twice ("--target"));
      --  A missing value is answered with the values, and a C compiler's
      --  `-g` with the option that gives what it asked for.
      Same (["compile", "main.ldn", "--debug"], ["main.ldn", "--debug="],
            "--debug needs a value");
      Same (["compile", "main.ldn", "--debug"], ["main.ldn", "--debug="],
            "; it takes none, full or lines");
      Same (["compile", "-g", "main.ldn"], ["-g", "main.ldn"],
            "unknown option: -g; did you mean --debug=full?");
      Same (["compile", "-g1", "main.ldn"], ["-g1", "main.ldn"],
            "unknown option: -g1; did you mean --debug=lines?");
      Same (["compile", "-g0", "main.ldn"], ["-g0", "main.ldn"],
            "unknown option: -g0; did you mean --debug=none?");
      Landin.Testing.Check_Equal
        (Item, Cat.Value_Problem (Cat.Debug, ""),
         "--debug needs a value; it takes none, full or lines",
         "a missing value names the values");
      Landin.Testing.Check_Equal
        (Item, Landin.Driver.Usage, Cat.Usage,
         "the driver's usage is the catalogue's overview");
   end Option_Requirements_Are_One;

   --  D526: what run refuses, before it makes a directory.
   procedure Run_Refusals (Item : in out Landin.Testing.Context);
   procedure Run_Refusals (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Refused (Args : Landin.Platform.Path_List; Expected : String);
      procedure Refused (Args : Landin.Platform.Path_List; Expected : String)
      is
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (Args, Host, Tools, Meter, Built_For => Linux_Host);
      begin
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Result.Report), Expected),
            Expected & ": " & US.To_String (Result.Report));
      end Refused;
   begin
      Host.Add_File ("main.ldn", Source);
      Refused (["run", "--target=linux-arm64", "main.ldn"],
               "run runs a program on this compiler's own host, and not on"
               & " linux-arm64; build one for linux-arm64 with"
               & " refine compile --target=linux-arm64");
      Refused (["run"], "run needs a source to compile and run");
      Refused (["run", "--emit=exe", "main.ldn"],
               "--emit is not an option of run");
      Refused
        (["run", "-o", "prog", "main.ldn"], "-o is not an option of run");
      Refused (["run", "--keep-asm", "main.ldn"],
               "--keep-asm is not an option of run");
      Refused (["run", "--dry-run", "main.ldn"],
               "--dry-run is not an option of run");
      Refused (["run", "--depfile=x.d", "main.ldn"],
               "--depfile is not an option of run");
      Landin.Testing.Check_Equal
        (Item, Host.Private_Directory_Count, 0,
         "a refused request makes no directory");
      Landin.Testing.Check_Equal
        (Item, Tools.Run_Count, 0, "a refused request runs nothing");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["run", "--target=linux-x86-64", "--link=libc", "main.ldn"],
              Host, Tools, Meter, Built_For => Linux_Host);
      begin
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Launch_Program),
            "/virtual/tmp/refine-run-1/main",
            "the compiler's own host may be named");
      end;
   end Run_Refusals;

   --  D526: bare `refine FILE` says it checked and wrote nothing, unless
   --  -q; `refine check` stays silent.
   procedure Bare_Form_Says_It_Only_Checked
     (Item : in out Landin.Testing.Context);
   procedure Bare_Form_Says_It_Only_Checked
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Said (Args : Landin.Platform.Path_List; Expected : String);
      procedure Said (Args : Landin.Platform.Path_List; Expected : String) is
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (Args, Host, Tools, Meter, Built_For => Linux_Host);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 0,
            "it checks: " & US.To_String (Result.Report));
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Report), Expected,
            "what the check says on standard error");
      end Said;
   begin
      Host.Add_File ("main.ldn", Source);
      Said (["main.ldn"],
            "refine: checked main.ldn and wrote nothing; run it with"
            & " `refine run main.ldn`, or build it with"
            & " `refine compile main.ldn -o main`" & ASCII.LF);
      Said (["-q", "main.ldn"], "");
      Said (["main.ldn", "--quiet"], "");
      Said (["check", "main.ldn"], "");
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "checking writes nothing");
      --  D731: the commands it names repeat what chose the program, and
      --  name only what the target can do, the same on every host.
      Said (["--target=linux-x86-64", "--optimize=speed", "main.ldn",
             "--build-report=report.json"],
            "refine: checked main.ldn and wrote no program; run it with"
            & " `refine run --target=linux-x86-64 --optimize=speed"
            & " main.ldn`, or build it with `refine compile"
            & " --target=linux-x86-64 --optimize=speed main.ldn -o main`"
            & ASCII.LF);
      Said (["--target=linux-arm64", "--level=armv8.1-a", "main.ldn"],
            "refine: checked main.ldn and wrote nothing; run it with"
            & " `refine run --target=linux-arm64 --level=armv8.1-a"
            & " main.ldn`, or build it with `refine compile"
            & " --target=linux-arm64 --level=armv8.1-a main.ldn -o main`"
            & ASCII.LF);
      Host.Add_Firmware_Library;
      Host.Add_File ("firmware.ldn",
        "public start: () -> noreturn = loop do end loop end start");
      Said (["--target=cortex-m0", "firmware.ldn"],
            "refine: checked firmware.ldn and wrote nothing; build it with"
            & " `refine compile --target=cortex-m0 --firmware-entry=NAME"
            & " firmware.ldn -o firmware`" & ASCII.LF);
      Said (["--target=cortex-m0", "--firmware-entry=start",
             "firmware.ldn"],
            "refine: checked firmware.ldn and wrote nothing; build it with"
            & " `refine compile --target=cortex-m0 --firmware-entry=start"
            & " firmware.ldn -o firmware`" & ASCII.LF);
      --  A module with no `main` is not offered to `run` or `compile`,
      --  which would refuse it; the line says what it lacks.
      Host.Add_File ("lib.ldn",
        "public lib: () -> (n: u32) =" & ASCII.LF & "    n = 1"
        & ASCII.LF & "end lib" & ASCII.LF);
      Said (["lib.ldn"],
            "refine: checked lib.ldn as a module and wrote nothing; a"
            & " program to run or build needs `public main: () -> (code:"
            & " i32)`" & ASCII.LF);
      Said (["--target=linux-arm64", "lib.ldn",
             "--build-report=report.json"],
            "refine: checked lib.ldn as a module and wrote no program; a"
            & " program to run or build needs `public main: () -> (code:"
            & " i32)`" & ASCII.LF);
      Host.Add_File ("my game.ldn", Source);
      Said (["my game.ldn"],
            "refine: checked 'my game.ldn' and wrote nothing; run it with"
            & " `refine run 'my game.ldn'`, or build it with"
            & " `refine compile 'my game.ldn' -o 'my game'`" & ASCII.LF);
   end Bare_Form_Says_It_Only_Checked;

   --  D524: -L takes its directory as a C compiler's does, after a
   --  space, glued or after `=`, repeatably, on compile, run and check.
   procedure Library_Directory_Option
     (Item : in out Landin.Testing.Context);
   procedure Library_Directory_Option
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
   begin
      Host.Add_File ("main.ldn", Source);
      Host.Add_Directory ("vendor");
      Host.Add_Directory ("other");
      Host.Add_Directory ("/opt/third");
      declare
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc", "--dry-run",
             "-L", "vendor", "-Lother", "-L=/opt/third", "main.ldn", "-o",
             "prog"], Host, Tools, Meter);
      begin
         Landin.Testing.Check
           (Item, Result.Status = 0
              and then Contains
                (US.To_String (Result.Output),
                 "run [""x86_64-pc-linux-gnu-gcc"","
                 & """-L/virtual/compile/vendor"","
                 & """-L/virtual/compile/other"",""-L/opt/third"","
                 & """-Wl,-rpath,/virtual/compile/vendor"","
                 & """-Wl,-rpath,/virtual/compile/other"","
                 & """-Wl,-rpath,/opt/third"",""prog.s"""),
            "each spelling of -L reaches the link in order: "
            & US.To_String (Result.Output) & US.To_String (Result.Report));
      end;
      declare
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["fmt", "-L", "vendor", "main.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then Contains
                (US.To_String (Result.Report), "-L is not an option of fmt"),
            "fmt takes no -L: " & US.To_String (Result.Report));
      end;
      declare
         Result : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["check", "--target=linux-x86-64", "--link=libc", "-L", "vendor",
             "main.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 0, "check takes -L: "
            & US.To_String (Result.Report));
      end;
   end Library_Directory_Option;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "commands", "options before their command",
         Options_Before_Their_Command'Access);
      Landin.Testing.Register
        (Into, "commands", "check takes what compile takes",
         Check_Takes_What_Compile_Takes'Access);
      Landin.Testing.Register
        (Into, "commands", "version identity", Version_Identity'Access);
      Landin.Testing.Register
        (Into, "commands", "version names the library",
         Version_Library'Access);
      Landin.Testing.Register
        (Into, "commands", "warning controls", Warning_Controls'Access);
      Landin.Testing.Register
        (Into, "commands", "JSON fixes preserve structure", JSON_Fixes'Access);
      Landin.Testing.Register (Into, "commands", "help and queries",
                              Help_And_Queries'Access);
      Landin.Testing.Register
        (Into, "commands", "command grammar", Grammar'Access);
      Landin.Testing.Register (Into, "commands", "placement and compatibility",
                              Placement_And_Compatibility'Access);
      Landin.Testing.Register (Into, "commands", "response files",
                              Response_Files'Access);
      Landin.Testing.Register (Into, "commands", "emission and dependencies",
                              Emission_And_Depfile'Access);
      Landin.Testing.Register (Into, "commands", "dry run", Dry_Run'Access);
      Landin.Testing.Register
        (Into, "commands", "run compiles and runs",
         Run_Compiles_And_Runs'Access);
      Landin.Testing.Register
        (Into, "commands", "run reports a signal",
         Run_Reports_A_Signal'Access);
      Landin.Testing.Register
        (Into, "commands", "run removes its directory",
         Run_Removes_Its_Directory'Access);
      Landin.Testing.Register
        (Into, "commands", "run refusals", Run_Refusals'Access);
      Landin.Testing.Register
        (Into, "commands", "option requirements are one",
         Option_Requirements_Are_One'Access);
      Landin.Testing.Register
        (Into, "commands", "the bare form says it only checked",
         Bare_Form_Says_It_Only_Checked'Access);
      Landin.Testing.Register
        (Into, "commands", "-L names a library directory",
         Library_Directory_Option'Access);
      Landin.Testing.Register (Into, "commands", "diagnostic presentation",
                              Presentation'Access);
   end Register;
end Landin.Tests.Commands_Suite;
