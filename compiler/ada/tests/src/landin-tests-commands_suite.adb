with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Commands;
with Landin.Commands.Catalogue;
with Landin.Driver;
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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
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
