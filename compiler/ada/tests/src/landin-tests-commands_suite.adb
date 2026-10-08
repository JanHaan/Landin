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
      end Help;
   begin
      Host.Raise_On_Read;
      Help (["compile", "--help"]);
      Help (["--help", "compile"]);
      Help (["help", "compile"]);
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (["version", "--json"], Host, Tools, Meter);
         Doc : Landin.Json.Document;
      begin
         Landin.Json.Parse (Doc, US.To_String (Result.Output));
         Landin.Testing.Check (Item, Landin.Json.Ok (Doc),
                               "version query is structured JSON");
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
            US.Append (Expected, ASCII.LF);
            Landin.Testing.Check_Equal
              (Item, Human.Status, 0, "version succeeds");
            Landin.Testing.Check_Equal
              (Item, US.To_String (Human.Output), US.To_String (Expected),
               "one-line banner");
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
           (["compile", "--target=linux-x86-64", "--emit", "asm",
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
           (["compile", "--target=linux-x86-64", "--emit=asm", "main.ldn",
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
           (["compile", "--target=linux-x86-64", "--dry-run", "main.ldn",
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
           (["compile", "--target=linux-x86-64", "--emit=asm", "main.ldn",
             "-o=base.s"], Host, Tools, Meter);
         Allowed : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--emit=asm", "main.ldn",
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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "commands", "version identity", Version_Identity'Access);
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
      Landin.Testing.Register (Into, "commands", "diagnostic presentation",
                              Presentation'Access);
   end Register;
end Landin.Tests.Commands_Suite;
