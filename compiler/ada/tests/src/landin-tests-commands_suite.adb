with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;
with Landin.Build_Identity;
with Landin.Commands;
with Landin.Commands.Catalogue;
with Landin.Driver;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Json;
with Landin.Platform;
with Landin.Splits.Bindings;
with Landin.Splits.Site;
with Landin.Splits.Svd;
with Landin.Platform.Native;
with Landin.Testing.Fakes;

package body Landin.Tests.Commands_Suite is
   package US renames Ada.Strings.Unbounded;
   Source : constant String :=
     "public main: () -> (code: i32) = code = 0 end main";
   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) /= 0);

   --  D1292: `refine site` resolves a panic site or a caller's three
   --  coordinates against the build its table was written with, and no
   --  other: assembly by its SHA-256, an ELF by `.landin_id` or its GNU
   --  build ID, a Mach-O by `__TEXT,__landin_id` and its dSYM by UUID.
   --  Every file is the fake filesystem's.
   procedure Site_Is_A_Subcommand
     (Item : in out Landin.Testing.Context);

   procedure Site_Is_A_Subcommand
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      LF : constant Character := Character'Val (10);
      NUL : constant Character := Character'Val (0);
      Build : constant String (1 .. 64) := [others => 'a'];
      Other : constant String (1 .. 64) := [others => 'b'];
      Assembly : constant String := "assembly" & LF;
      --  Filesystem bytes: a colon, a quote and a byte that is no UTF-8.
      Path : constant String :=
        "folder:with""quotes/" & Character'Val (16#FF#) & ".ldn";
      Path_Hex : constant String :=
        "666f6c6465723a776974682271756f7465732fff2e6c646e";

      function Table (Id : String) return String is
        ("{""build_id"":""" & Id & """,""assembly_sha256"":"""
         & GNAT.SHA256.Digest (Assembly) & """,""files"":["
         & "{""file_id"":2,""path_hex"":""" & Path_Hex & ""","
         & """panic_base"":101,""byte_length"":19,"
         & """line_offsets"":[0,5,12]}]}");

      --  VALUE in COUNT little-endian bytes.
      function LE (Value : Natural; Count : Positive) return String;
      function LE (Value : Natural; Count : Positive) return String is
         Result : String (1 .. Count);
         Rest : Natural := Value;
      begin
         for Byte of Result loop
            Byte := Character'Val (Rest mod 256);
            Rest := Rest / 256;
         end loop;
         return Result;
      end LE;

      function Padded (Text : String; Count : Positive) return String is
        (Text & [1 .. Count - Text'Length => NUL]);

      --  A little-endian ELF of one section, NAME holding CONTENT, and
      --  its section names.
      function ELF (Wide : Boolean; Name, Content : String) return String;
      function ELF (Wide : Boolean; Name, Content : String) return String
      is
         Header : constant Natural := (if Wide then 64 else 52);
         Entry_Size : constant Natural := (if Wide then 64 else 40);
         Names : constant String := NUL & Name & NUL & ".shstrtab" & NUL;
         Content_At : constant Natural := Header;
         Names_At : constant Natural := Content_At + Content'Length;
         Table_At : constant Natural := Names_At + Names'Length;

         function Section (Name_At, Offset, Size : Natural) return String is
           (if Wide
            then LE (Name_At, 4) & LE (1, 4) & LE (0, 8) & LE (0, 8)
              & LE (Offset, 8) & LE (Size, 8) & LE (0, 24)
            else LE (Name_At, 4) & LE (1, 4) & LE (0, 4) & LE (0, 4)
              & LE (Offset, 4) & LE (Size, 4) & LE (0, 16));
      begin
         return Character'Val (16#7F#) & "ELF"
           & Character'Val (if Wide then 2 else 1) & Character'Val (1)
           & Character'Val (1) & LE (0, 9)
           & LE (2, 2) & LE (0, 2) & LE (1, 4)
           & (if Wide
              then LE (0, 8) & LE (0, 8) & LE (Table_At, 8)
              else LE (0, 4) & LE (0, 4) & LE (Table_At, 4))
           & LE (0, 4) & LE (Header, 2) & LE (0, 2) & LE (0, 2)
           & LE (Entry_Size, 2) & LE (3, 2) & LE (2, 2)
           & Content & Names
           & Section (0, 0, 0)
           & Section (1, Content_At, Content'Length)
           & Section (Name'Length + 2, Names_At, Names'Length);
      end ELF;

      --  The 32 bytes a build ID's 64 digits spell, all 16#aa#.
      Note : constant String :=
        LE (4, 4) & LE (32, 4) & LE (3, 4) & "GNU" & NUL
        & [1 .. 32 => Character'Val (16#AA#)];

      --  A thin arm64 Mach-O: an executable (2) with `__landin_id`
      --  holding ID, or a dSYM's DWARF file (10), and its UUID.
      function Mach_O (Kind : Natural; UUID : Character; Id : String)
        return String;
      function Mach_O (Kind : Natural; UUID : Character; Id : String)
        return String
      is
         Segment : constant String :=
           LE (16#19#, 4) & LE (152, 4) & Padded ("__TEXT", 16)
           & LE (0, 8) & LE (0, 8) & LE (0, 8) & LE (0, 8)
           & LE (0, 4) & LE (0, 4) & LE (1, 4) & LE (0, 4)
           & Padded ("__landin_id", 16) & Padded ("__TEXT", 16)
           & LE (0, 8) & LE (Id'Length, 8) & LE (32 + 24 + 152, 4)
           & LE (0, 28);
         Commands : constant String :=
           LE (16#1B#, 4) & LE (24, 4) & [1 .. 16 => UUID]
           & (if Kind = 2 then Segment else "");
      begin
         return Character'Val (16#CF#) & Character'Val (16#FA#)
           & Character'Val (16#ED#) & Character'Val (16#FE#)
           & LE (16#0100000C#, 4) & LE (0, 4) & LE (Kind, 4)
           & LE ((if Kind = 2 then 2 else 1), 4)
           & LE (Commands'Length, 4) & LE (0, 4) & LE (0, 4)
           & Commands & (if Kind = 2 then Id else "");
      end Mach_O;

      --  `refine site WORDS` is `refine-site WORDS` (D1383).
      function Run (Words : Landin.Platform.Path_List)
        return Landin.Driver.Outcome;
      function Run (Words : Landin.Platform.Path_List)
        return Landin.Driver.Outcome
      is
         Rest : Landin.Platform.Path_List := Words;
      begin
         Rest.Delete_First;
         return Landin.Splits.Site.Execute (Rest, Host, Tools);
      end Run;

      procedure Answers (Words : Landin.Platform.Path_List; Line : String);
      procedure Answers (Words : Landin.Platform.Path_List; Line : String)
      is
         Got : constant Landin.Driver.Outcome := Run (Words);
      begin
         Landin.Testing.Check
           (Item, Got.Status = Landin.Driver.Status_Success
              and then US.To_String (Got.Output) = Line & LF,
            Line & " is answered: " & US.To_String (Got.Output)
            & US.To_String (Got.Report));
      end Answers;

      procedure Refuses
        (Words : Landin.Platform.Path_List; Code, Part : String);
      procedure Refuses
        (Words : Landin.Platform.Path_List; Code, Part : String)
      is
         Got : constant Landin.Driver.Outcome := Run (Words);
         Said : constant String := US.To_String (Got.Report);
      begin
         Landin.Testing.Check
           (Item, Got.Status = Landin.Driver.Status_Reported
              and then US.Length (Got.Output) = 0
              and then Contains (Said, "error[" & Code & "]")
              and then Contains (Said, Part),
            Code & " " & Part & " is reported: " & Said);
      end Refuses;

      function Kind_Name (Kind : Natural) return String is
        (case Kind is
            when 0 => "out_of_range", when 1 => "overflow",
            when 2 => "bad_conversion", when 3 => "unreachable",
            when others => "stack_exhausted");

      procedure Misused (Words : Landin.Platform.Path_List);
      procedure Misused (Words : Landin.Platform.Path_List) is
      begin
         Landin.Testing.Check_Equal
           (Item, Run (Words).Status, Landin.Driver.Status_Misuse,
            "one site or three coordinates are asked for");
      end Misused;
   begin
      Host.Add_File ("p.s", Assembly);
      Host.Add_File ("p.s.sources.json", Table (Build));
      Host.Add_File ("other.s", "another assembly" & LF);
      Host.Add_File ("other.json", Table (Other));
      Host.Add_File ("broken.json", "{""build_id"":");
      Host.Add_File ("bare.json", "{""files"":[]}");
      Host.Add_File ("fw.elf", ELF (False, ".landin_id", Build));
      Host.Add_File
        ("hosted", ELF (True, ".note.gnu.build-id", Note));
      Host.Add_File ("stripped", ELF (True, ".text", "code"));
      Host.Add_File ("cut.elf", ELF (False, ".landin_id", Build) (1 .. 60));
      Host.Add_File ("app", Mach_O (2, 'u', Build));
      Host.Add_File ("app.dwarf", Mach_O (10, 'u', ""));
      Host.Add_File ("wrong.dwarf", Mach_O (10, 'v', ""));
      --  A site is five check families at each source byte.
      for Kind in 0 .. 4 loop
         Answers (["site", "p.s",
                   Ada.Strings.Fixed.Trim
                     (Natural'Image (101 + 5 * 14 + Kind),
                      Ada.Strings.Both)],
                  Path & ":3:3 (" & Kind_Name (Kind) & ")");
      end loop;
      Answers (["site", "p.s", "0xAC"], Path & ":3:3 (overflow)");
      Answers (["site", "p.s", "101"], Path & ":1:1 (out_of_range)");
      Answers (["site", "p.s", "200"], Path & ":3:8 (stack_exhausted)");
      --  A caller's coordinates name the file and are printed as given.
      Answers (["site", "p.s", "2", "42", "9"], Path & ":42:9");
      --  Each kind of build is held to the table's identity.
      Answers (["site", "--map=p.s.sources.json", "fw.elf", "172"],
               Path & ":3:3 (overflow)");
      Answers (["site", "hosted", "--map", "p.s.sources.json", "172"],
               Path & ":3:3 (overflow)");
      Answers (["site", "--map=p.s.sources.json", "app", "2", "1", "1"],
               Path & ":1:1");
      Answers (["site", "--map=p.s.sources.json", "--dsym=app.dwarf",
                "app", "172"], Path & ":3:3 (overflow)");
      Refuses (["site", "--map=p.s.sources.json", "other.s", "172"],
               "L0689", "other.s is not the build p.s.sources.json was"
               & " written with");
      Refuses (["site", "--map=other.json", "fw.elf", "172"], "L0689",
               "fw.elf is build " & Build & ", and other.json was written"
               & " with build " & Other);
      Refuses (["site", "--map=other.json", "hosted", "172"], "L0689",
               "hosted is build " & Build);
      Refuses (["site", "--map=other.json", "app", "172"], "L0689",
               "app is build " & Build);
      Refuses (["site", "--map=p.s.sources.json", "stripped", "172"],
               "L0689", "stripped carries no build identity");
      Refuses (["site", "--map=p.s.sources.json", "cut.elf", "172"],
               "L0689", "cut.elf is not a complete");
      Refuses (["site", "--map=p.s.sources.json", "--dsym=wrong.dwarf",
                "app", "172"], "L0689", "wrong.dwarf is not the dSYM of app");
      Refuses (["site", "--map=p.s.sources.json", "--dsym=app.dwarf",
                "fw.elf", "172"], "L0689", "app.dwarf is not the dSYM of");
      Refuses (["site", "--map=p.s.sources.json", "app.dwarf", "172"],
               "L0689", "name the executable");
      --  What the table does not hold.
      Refuses (["site", "p.s", "0"], "L0690", "site 0 is the compiler's");
      Refuses (["site", "p.s", "100"], "L0690", "site 100 is in no file");
      Refuses (["site", "p.s", "201"], "L0690", "site 201 is in no file");
      Refuses (["site", "p.s", "4294967296"], "L0690", "is not a site");
      Refuses (["site", "p.s", "12x"], "L0690", "`12x` is not a site");
      Refuses (["site", "p.s", "8", "42", "9"], "L0690",
               "file 8 is not one file of p.s.sources.json");
      Refuses (["site", "p.s", "2", "0", "9"], "L0690",
               "three positive numbers");
      --  A table that is none, and one that is not there.
      Refuses (["site", "--map=broken.json", "p.s", "172"], "L0688",
               "broken.json is not a source table refine wrote");
      Refuses (["site", "--map=bare.json", "p.s", "172"], "L0688",
               "it needs build_id, assembly_sha256 and files");
      Refuses (["site", "fw.elf", "172"], "L0003",
               "cannot read the source table fw.elf.sources.json: it does"
               & " not exist; refine compile --panic-map writes it");
      Refuses (["site", "absent", "172"], "L0003",
               "cannot read the build absent: it does not exist");
      Misused (["site"]);
      Misused (["site", "p.s"]);
      Misused (["site", "p.s", "2", "42"]);
      Misused (["site", "p.s", "2", "42", "9", "1"]);
      Landin.Testing.Check
        (Item, Tools.Run_Count = 0, "no tool is run to resolve a site");
   end Site_Is_A_Subcommand;

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
                  if Name = "linux-x86-64" then
                     declare
                        Features : constant J.Value :=
                          J.Member (Doc, Row, "features");
                        V4 : constant J.Value :=
                          J.Member (Doc, Features, "x86-64-v4");
                     begin
                        Landin.Testing.Check_Equal
                          (Item, J.Length (Doc, J.Member
                             (Doc, Features, "x86-64-v1")), 0,
                           "the x86-64 baseline assumes no feature");
                        Landin.Testing.Check_Equal
                          (Item, J.Text (Doc, J.Element
                             (Doc, V4, J.Length (Doc, V4))), "avx512vl",
                           "x86-64-v4 lists its features, AVX-512 last");
                     end;
                  end if;
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
         --  Which cores each level is, in both queries.
         Landin.Testing.Check
           (Item, Contains (US.To_String (Human.Output),
              "cortex-m0: armv6-m, armv7-m, armv7e-m, armv8-m.main;"
              & " debug: lines" & ASCII.LF
              & "  cores by level: armv6-m: cortex-m0, cortex-m0plus;"
              & " armv7-m: cortex-m3; armv7e-m: cortex-m4, cortex-m7;"
              & " armv8-m.main: cortex-m33" & ASCII.LF)
            and then Contains (US.To_String (Human.Output),
              "  cores by level: rv32imc: esp-rv32imc; rv32imac: hazard3,"
              & " sifive-e31, esp-rv32imac-clic" & ASCII.LF)
            and then Contains (US.To_String (Human.Output),
              "  cores by level: xtensa-esp32: xtensa-lx6; xtensa-esp32s3:"
              & " xtensa-lx7" & ASCII.LF)
            and then not Contains (US.To_String (Human.Output),
              "x86-64-v4; debug: full" & ASCII.LF & "  cores"),
            "the plain query names each firmware level's cores: "
            & US.To_String (Human.Output));
         Landin.Testing.Check
           (Item, Contains (US.To_String (Machine.Output),
              """cores"":[{""name"":""cortex-m0"",""level"":""armv6-m""},"
              & "{""name"":""cortex-m0plus"",""level"":""armv6-m""},"
              & "{""name"":""cortex-m3"",""level"":""armv7-m""},"
              & "{""name"":""cortex-m4"",""level"":""armv7e-m""},"
              & "{""name"":""cortex-m7"",""level"":""armv7e-m""},"
              & "{""name"":""cortex-m33"",""level"":""armv8-m.main""}]")
            and then Contains (US.To_String (Machine.Output),
              """cores"":[]"),
            "the structured query lists each core with its level: "
            & US.To_String (Machine.Output));
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
      --  D1240: the text comes from the library's citations file, found
      --  beside refine or where `--library` says, an option explain takes
      --  as a compilation does.
      declare
         function With_Citations
           return Landin.Testing.Fakes.Fake_Filesystem;

         function With_Citations
           return Landin.Testing.Fakes.Fake_Filesystem is
         begin
            return Made : Landin.Testing.Fakes.Fake_Filesystem do
               Made.Add_Citations;
            end return;
         end With_Citations;

         Beside : constant Landin.Testing.Fakes.Fake_Filesystem :=
           With_Citations;
         Before : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["explain", "--full", "D280"], Beside, Tools, Meter);
         After : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["explain", "D280", "--full"], Beside, Tools, Meter);
         Nowhere : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["explain", "--library=/nowhere", "D280"], Beside, Tools,
              Meter);
         Spaced : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["explain", "D280", "--library", "/elsewhere"], Beside,
              Tools, Meter);
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
         Landin.Testing.Check
           (Item, Nowhere.Status = 1
                  and then Ada.Strings.Fixed.Index
                    (US.To_String (Nowhere.Report),
                     "/nowhere/citations.txt, which is not there") > 0,
            "explain --library names where the citations are read");
         Landin.Testing.Check
           (Item, Spaced.Status = 1
                  and then Ada.Strings.Fixed.Index
                    (US.To_String (Spaced.Report),
                     "/elsewhere/citations.txt, which is not there") > 0,
            "the command line hands --library DIR to explain as one word");
      end;
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "informational commands write no files");
      Landin.Testing.Check_Equal
        (Item, Tools.Run_Count, 0, "informational commands invoke no tools");
      Landin.Testing.Check
        (Item, not Landin.Commands.Is_Server (["lsp", "--help"], Host),
         "server help never starts the protocol");
   end Help_And_Queries;

   procedure Actionable_Command_Guidance
     (Item : in out Landin.Testing.Context);

   procedure Actionable_Command_Guidance
     (Item : in out Landin.Testing.Context)
   is
      package C renames Landin.Commands.Catalogue;
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      Lsp : constant String := C.Usage (C.Server);
      Completion : constant String := C.Usage (C.Completion);
      Result : Landin.Driver.Outcome;
   begin
      Landin.Testing.Check
        (Item, Contains (Lsp, "--stdio") and then Contains (Lsp, "--help")
         and then not Contains (Lsp, "--color")
         and then not Contains (Lsp, "--diagnostics")
         and then not Contains (Lsp, "--verbose")
         and then not Contains (Lsp, "--quiet"),
         "server help advertises only supported options");
      Landin.Testing.Check
        (Item, Contains (C.Usage (C.Compile), "--color")
         and then Contains (C.Usage (C.Format), "--diagnostics"),
         "other commands retain their presentation options");
      --  A supervisor's route, which nothing else held the help to.
      Landin.Testing.Check
        (Item, Contains (C.Usage (C.Run),
           "Ctrl-C reaches the program through the terminal's" & ASCII.LF
           & "foreground process group. A supervisor that signals" & ASCII.LF
           & "refine alone should send SIGTERM or SIGHUP, which" & ASCII.LF
           & "refine forwards before it cleans up; SIGINT and" & ASCII.LF
           & "SIGQUIT sent to refine alone are ignored."),
         "run help says how a supervisor stops a program");
      --  Where the build report is described and where diagnostics go,
      --  in every command that compiles.
      for Command in C.Check .. C.Run loop
         Landin.Testing.Check
           (Item, Contains (C.Usage (Command),
              "The build report's fields are listed under ""The build"
              & ASCII.LF & "report"" in compiler/ada/README.md.")
            and then Contains (C.Usage (Command),
              "Diagnostic format on standard error: human (default),"
              & " short, json"),
            C.Name (Command) & " help names the build report's fields"
            & " and the diagnostics' stream");
      end loop;
      --  An option written as a word of a longer one is offered it.
      Result := Landin.Commands.Execute
        (["check", "--target=rv32", "--firmware=start", "main.ldn"],
         Host, Tools, Meter);
      Landin.Testing.Check
        (Item, Result.Status = 2
         and then Contains (US.To_String (Result.Report),
           "unknown option: --firmware=start; did you mean --firmware-entry"
           & " or --firmware-layout?"),
         "a word of two options offers both: "
         & US.To_String (Result.Report));
      Result := Landin.Commands.Execute
        (["check", "--target=rv32", "--entry=start", "main.ldn"],
         Host, Tools, Meter);
      Landin.Testing.Check
        (Item, Result.Status = 2
         and then Contains (US.To_String (Result.Report),
           "unknown option: --entry=start; did you mean --firmware-entry?"),
         "the last word of an option offers it: "
         & US.To_String (Result.Report));
      Landin.Testing.Check
        (Item, Contains (Completion, "source <(refine completion bash)")
         and then Contains (Completion, "autoload -Uz compinit; compinit")
         and then Contains (Completion, "source <(refine completion zsh)")
         and then Contains (Completion, "refine completion fish | source"),
         "each shell has an activation example");
      Result := Landin.Commands.Execute
        (["fmt", "--stdout", "-"], Host, Tools, Meter);
      Landin.Testing.Check
        (Item, Result.Status = 2
         and then Contains (US.To_String (Result.Report),
                            "fmt does not read standard input")
         and then Contains (US.To_String (Result.Report),
                            "refine fmt --stdout source.ldn")
         and then Contains (US.To_String (Result.Report), "refine lsp"),
         "stdin refusal names file and editor routes");
      Host.Add_File ("main.ldn", Source);
      Host.Add_File ("notes", "some data that is not Landin source");
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "main.ldn", "notes"],
         Host, Tools, Meter, Built_For => "x86_64-pc-linux-gnu");
      Landin.Testing.Check
        (Item, Result.Status = 1
         and then Contains (US.To_String (Result.Report),
                            "refine run ""main.ldn"" -- ""notes"""),
         "data parsed as a second source gets the separator route: "
         & US.To_String (Result.Report));
      declare
         Structured : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["run", "--diagnostics=json", "--link=libc", "main.ldn",
               "notes"], Host, Tools, Meter,
              Built_For => "x86_64-pc-linux-gnu");
         Found, Rendered : Boolean := False;
      begin
         for Index in 1 .. Landin.Diagnostics.Count (Structured.Found) loop
            declare
               D : constant Landin.Diagnostics.Diagnostic :=
                 Landin.Diagnostics.Get (Structured.Found, Index);
            begin
               for N in 1 .. Landin.Diagnostics.Note_Count (D) loop
                  if Contains
                    (Landin.Diagnostics.Nth_Note (D, N),
                     "refine run ""main.ldn"" -- ""notes""")
                  then
                     Found := True;
                     Rendered := Rendered or else Contains
                       (US.To_String (Structured.Report), Landin.Json.Quoted
                          (Landin.Diagnostics.Nth_Note (D, N)));
                  end if;
               end loop;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Structured.Status = 1 and then Found,
            "structured diagnostics retain the same separator repair");
         Landin.Testing.Check
           (Item, Rendered, "JSON rendering includes the separator repair");
      end;
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "main.ldn", "--", "notes"],
         Host, Tools, Meter, Built_For => "x86_64-pc-linux-gnu");
      Landin.Testing.Check
        (Item, Result.Status = 0
         and then Natural (Result.Launch_Arguments.Length) = 1
         and then Result.Launch_Arguments (1) = "notes",
         "the suggested separator compiles and forwards the argument");
      Landin.Commands.Launch (Result, Host, Tools);
      Host.Add_File ("notes", "value: i32 = 1");
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "main.ldn", "notes"],
         Host, Tools, Meter, Built_For => "x86_64-pc-linux-gnu");
      Landin.Testing.Check
        (Item, Result.Status = 0,
         "an additional source needs no .ldn suffix");
      Landin.Commands.Launch (Result, Host, Tools);
   end Actionable_Command_Guidance;

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
              Landin.Commands.Execute
                (["version"], Host, Tools, Meter, Shipped => "");
            Alias_Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute
                (["--version"], Host, Tools, Meter, Shipped => "");
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
            US.Append (Expected, ASCII.LF & "library: none" & ASCII.LF
                       & "citations: none" & ASCII.LF
                       & "split commands: none" & ASCII.LF);
            Landin.Testing.Check_Equal
              (Item, Human.Status, 0, "version succeeds");
            Landin.Testing.Check_Equal
              (Item, US.To_String (Human.Output), US.To_String (Expected),
               "banner, library, citations and split commands");
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
         Landin.Testing.Check
           (Item, Contains (US.To_String (Human.Output),
                            ASCII.LF & "library: /opt/landin/lib/landin"
                            & ASCII.LF),
            "the installed library is reported");
         J.Parse (Doc, US.To_String (Machine.Output));
         Landin.Testing.Check
           (Item, J.Ok (Doc)
            and then J.Is_Kind
              (Doc, J.Member (Doc, J.Root (Doc), "library"), J.String_Value)
            and then J.Text (Doc, J.Member (Doc, J.Root (Doc), "library"))
              = "/opt/landin/lib/landin",
            "the installed library is a JSON string");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Named.Output),
                            ASCII.LF & "library: /elsewhere" & ASCII.LF),
            "--library replaces it");
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
         Plain : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["check", "--target=linux-x86-64", "main.ldn"], Host, Tools,
            Meter);
         Bare : constant Landin.Driver.Outcome := Landin.Commands.Execute
           (["--target=linux-x86-64", "main.ldn"], Host, Tools, Meter);
      begin
         Landin.Testing.Check_Equal (Item, Before.Status, 0, "check succeeds");
         Landin.Testing.Check_Equal
           (Item, Before.Status, After.Status,
            "shared option placement agrees");
         --  D1463: a source named without a command is refused.
         Landin.Testing.Check_Equal
           (Item, Bare.Status, Landin.Driver.Status_Misuse,
            "a bare source is refused");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Before.Trace), US.To_String (After.Trace),
            "equal requests give equal verbose output");
         Landin.Testing.Check
           (Item, Contains (US.To_String (After.Trace),
                            "  source: ""main.ldn""" & ASCII.LF),
            "-v names every source the request read: "
            & US.To_String (After.Trace));
         Landin.Testing.Check
           (Item, US.Length (Plain.Trace) = 0,
            "a request without -v names none");
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

   procedure Response_Inputs_Survive
     (Item : in out Landin.Testing.Context);
   procedure Response_Inputs_Survive
     (Item : in out Landin.Testing.Context) is
      Meter : Landin.Platform.Unmetered;
   begin
      for Attempt in 1 .. 4 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Result : Landin.Driver.Outcome;
            Read : Landin.Platform.Read_Status;
            Content : US.Unbounded_String;
            Outer : constant String := "@inner";
            Inner : constant String :=
              "check --target=linux-x86-64 main.ldn";
            Option : constant String :=
              (case Attempt is
                  when 1 => "--build-report=outer",
                  when 2 => "--stage-report=inner",
                  when 3 => "--build-report=alias",
                  when 4 => "--stage-report=alias");
         begin
            Host.Add_File ("main.ldn", Source);
            Host.Add_File ("outer", Outer);
            Host.Add_File ("inner", Inner);
            Host.Add_Alias ("alias", "inner");
            Result := Landin.Commands.Execute
              (["@outer", Option], Host, Tools, Meter);
            Landin.Testing.Check
              (Item, Result.Status /= Landin.Driver.Status_Success
               and then Contains (US.To_String (Result.Report), "output")
               and then Contains (US.To_String (Result.Report), "retry"),
               "a response collision is actionable: "
               & US.To_String (Result.Report));
            Host.Read_File ("outer", Content, Read);
            Landin.Testing.Check_Equal
              (Item, US.To_String (Content), Outer,
               "outer response remains the consumed generation");
            Host.Read_File ("inner", Content, Read);
            Landin.Testing.Check_Equal
              (Item, US.To_String (Content), Inner,
               "nested response and its alias remain untouched");
         end;
      end loop;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Source);
         Result := Landin.Commands.Execute
           (["compile", "--target=linux-x86-64", "--link=libc", "-vv",
             "main.ldn", "-o=program"], Host, Tools, Meter);
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Success
            and then Contains (US.To_String (Result.Trace), "program.s")
            and then not Contains
              (US.To_String (Result.Trace), ".refine-publication"),
            "verbose tool traces retain logical output paths: "
            & US.To_String (Result.Trace));
      end;
   end Response_Inputs_Survive;

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
               "--library=/opt/lib is an option of check, compile, run,"
               & " explain and version, and follows its command: refine"
               & " compile --library=/opt/lib ...");
      Refused (["--emit=asm", "check", "a.ldn"],
               "--emit=asm is an option of compile, not of check, and"
               & " follows its command: refine compile --emit=asm ...");
      Refused (["--target=linux-x86-64", "--version"],
               "--target=linux-x86-64 is an option of check, compile and"
               & " run, not of version");
      --  D1463: with no command, the request is named again after the
      --  command of the option `check` does not take.
      Refused (["-o", "x.s", "main.ldn"],
               "unknown command: main.ldn; name the command first:"
               & " refine compile -o x.s main.ldn");
      Refused (["--library=/opt/lib", "--depfile=d", "main.ldn"],
               "name the command first: refine compile --library=/opt/lib"
               & " --depfile=d main.ldn");
      Refused (["--root=lib"],
               "--root=lib is an option of check, compile and run, and"
               & " follows its command: refine check --root=lib ...");
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
                    & " --target=cortex-m0, --target=rv32 or"
                    & " --target=xtensa"),
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
                       Contains (Argument, "/main")
                       and then Argument /=
                         "/virtual/tmp/refine-run-1/main"),
         "the link writes a private generation before public launch");
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
      --  D1528: a closed pipe is its reader leaving, and ends refine as
      --  quietly as a shell's pipeline.
      Tools.Set_Program_Result (0, Signal => 13, Signal_Name => "SIGPIPE");
      Result := Landin.Commands.Execute
        (["run", "--link=libc", "game.ldn"], Host, Tools, Meter,
         Built_For => Linux_Host);
      Landin.Commands.Launch (Result, Host, Tools);
      Landin.Testing.Check
        (Item, Result.Status = 141
           and then US.To_String (Result.Report) = ""
           and then not Host.Exists ("/virtual/tmp/refine-run-3"),
         "a program a closed pipe ended ends refine quietly: "
         & US.To_String (Result.Report));
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

   --  D1463: a source named without a command is refused, naming the
   --  whole request after the command that takes it, as a shell reads it
   --  back; `refine check` stays silent (D526).
   procedure Bare_Form_Is_Refused
     (Item : in out Landin.Testing.Context);
   procedure Bare_Form_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      procedure Refused (Args : Landin.Platform.Path_List; Says : String);
      procedure Refused (Args : Landin.Platform.Path_List; Says : String) is
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (Args, Host, Tools, Meter, Built_For => Linux_Host);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "a bare source is misuse: " & US.To_String (Result.Report));
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Report),
            "error[L0002]: " & Says & ASCII.LF,
            "the refusal names the command");
      end Refused;
   begin
      Host.Raise_On_Read;
      Refused (["main.ldn"],
               "unknown command: main.ldn; name the command first:"
               & " refine check main.ldn");
      Refused (["-q", "main.ldn"],
               "unknown command: main.ldn; name the command first:"
               & " refine check -q main.ldn");
      Refused (["--target=cortex-m0", "--firmware-entry=start",
                "firmware.ldn"],
               "unknown command: firmware.ldn; name the command first:"
               & " refine check --target=cortex-m0 --firmware-entry=start"
               & " firmware.ldn");
      Refused (["--emit=asm", "main.ldn", "-o", "main.s"],
               "unknown command: main.ldn; name the command first:"
               & " refine compile --emit=asm main.ldn -o main.s");
      Refused (["my game.ldn"],
               "unknown command: my game.ldn; name the command first:"
               & " refine check 'my game.ldn'");
      Refused (["--", "-x.ldn"],
               "unknown command: -x.ldn; name the command first:"
               & " refine check -- -x.ldn");
      --  A typo of a command is refused the same way, with no source
      --  read.
      Refused (["chek", "main.ldn"],
               "unknown command: chek; refine help lists the commands; if"
               & " chek is a source: refine check chek main.ldn");
      Refused (["lib/"],
               "unknown command: lib/; name the command first:"
               & " refine check lib/");
      Landin.Testing.Check_Equal
        (Item, Host.Write_Count, 0, "a refusal writes nothing");
      declare
         Quiet_Host : Landin.Testing.Fakes.Fake_Filesystem;
         Result : Landin.Driver.Outcome;
      begin
         Quiet_Host.Add_File ("main.ldn", Source);
         Result := Landin.Commands.Execute
           (["check", "main.ldn"], Quiet_Host, Tools, Meter,
            Built_For => Linux_Host);
         Landin.Testing.Check_Equal
           (Item, Result.Status, 0, "check checks");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Report), "",
            "check says nothing of what it did not write");
      end;
   end Bare_Form_Is_Refused;

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

   --  `refine help reference` is recorded in
   --  compiler/tests/commands.reference, which check.py holds the front page's
   --  command table and docs/capabilities.md to, so a command or option
   --  the documents do not name is refused by a check that runs on every
   --  edit of them.  This case holds the record to the catalogue.  It
   --  reads the repository's file through the real filesystem, a
   --  deliberate exception: the record is of the checkout, not of a fake.
   procedure Reference_Is_Recorded
     (Item : in out Landin.Testing.Context);

   procedure Reference_Is_Recorded
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Platform.Native.Native_Filesystem;
      Text   : US.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      use type Landin.Platform.Read_Status;
   begin
      Host.Read_File ("../tests/commands.reference", Text, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Read_Ok,
         "compiler/tests/commands.reference is readable");
      if Status = Landin.Platform.Read_Ok then
         Landin.Testing.Check
           (Item, US.To_String (Text) = Landin.Commands.Catalogue.Reference,
            "compiler/tests/commands.reference is `refine help reference`;"
            & " after changing help, record it again from the checkout's"
            & " root with the refine this build made,"
            & " `REFINE help reference > compiler/tests/commands.reference`,"
            & " and run python3 check.py, which names any command or"
            & " option the documents do not");
      end if;
   end Reference_Is_Recorded;

   --  D1384, D1385, D1387, D1484-D1488: the dispatcher, on the fake host.
   --  A built-in command wins; a split command `refine` was built with is
   --  looked for beside it alone and refused when missing; any other name
   --  is looked for on the search path, the first directory winning.
   --  Each is asked to describe itself, within ten seconds, before it
   --  runs, and runs with the words after its name exactly as written and
   --  LANDIN_REFINE naming the refine that dispatched it.
   procedure Dispatcher (Item : in out Landin.Testing.Context);
   procedure Dispatcher (Item : in out Landin.Testing.Context) is
      use type Landin.Platform.Capture_Mode;
      Meter : Landin.Platform.Unmetered;
      Q : constant Character := '"';
      Shipped_Path : constant String :=
        "/opt/landin/libexec/landin/refine-probe";

      function Description
        (Name : String; Codes : String := "";
         Digest : String := Landin.Build_Identity.Source_Digest;
         Format : String := "landin-command-1") return String is
        ("{" & Q & "format" & Q & ":" & Q & Format & Q & ","
         & Q & "name" & Q & ":" & Q & Name & Q & ","
         & Q & "summary" & Q & ":" & Q & "the " & Name & " tool" & Q & ","
         & (if Digest = "" then ""
            else Q & "source_digest" & Q & ":" & Q & Digest & Q & ",")
         & Q & "codes" & Q & ":[" & Codes & "]}" & ASCII.LF);

      --  A host with refine in /opt/landin/bin.
      procedure Install (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure Install (Host : in out Landin.Testing.Fakes.Fake_Filesystem)
      is
      begin
         Host.Set_Executable_Directory ("/opt/landin/bin");
         Host.Add_Directory ("/opt/landin/libexec/landin");
      end Install;

      procedure Refused
        (Result : Landin.Driver.Outcome; Code : String;
         Needles : Landin.Platform.Path_List; What : String);
      procedure Refused
        (Result : Landin.Driver.Outcome; Code : String;
         Needles : Landin.Platform.Path_List; What : String)
      is
         Report : constant String := US.To_String (Result.Report);
      begin
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Reported
              and then Contains (Report, "error[" & Code & "]")
              and then US.Length (Result.Launch_Program) = 0,
            What & " is refused with " & Code & ", status 1: " & Report);
         for Needle of Needles loop
            Landin.Testing.Check
              (Item, Contains (Report, Needle),
               What & " names " & Needle & ": " & Report);
         end loop;
      end Refused;
   begin
      --  A built-in command wins over a refine-version on the path.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Tools.Add_Path_Program ("/usr/bin/refine-version");
         Result := Landin.Commands.Execute
           (["version"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, Tools.Run_Count = 0 and then Result.Status = 0
              and then US.Length (Result.Launch_Program) = 0,
            "a built-in command is never looked for outside refine");
      end;

      --  A shipped command beside refine, described compatibly, runs with
      --  its words as written and the caller named.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Host.Add_File (Shipped_Path, "");
         Tools.Add_Path_Program ("/usr/bin/refine-probe");
         Tools.Set_Result (0, Description ("probe"));
         Result := Landin.Commands.Execute
           (["probe", "--json", "@words", "--", ""], Host, Tools, Meter,
            Shipped => "other probe");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Launch_Program), Shipped_Path,
            "a shipped command runs from libexec/landin beside refine");
         Landin.Testing.Check
           (Item, Natural (Result.Launch_Arguments.Length) = 4
              and then Result.Launch_Arguments (1) = "--json"
              and then Result.Launch_Arguments (2) = "@words"
              and then Result.Launch_Arguments (3) = "--"
              and then Result.Launch_Arguments (4) = "",
            "the words after its name are its own, exactly as written");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Launch_Setting),
            "LANDIN_REFINE=/opt/landin/bin/refine",
            "it is told the refine that dispatched it (D1486)");
         declare
            Asked : constant Landin.Testing.Fakes.Tool_Call :=
              Tools.Call_At (1);
            Words : constant Landin.Platform.Path_List := Asked.Arguments;
         begin
            Landin.Testing.Check
              (Item, Tools.Run_Count = 1
                 and then US.To_String (Asked.Program) = Shipped_Path
                 and then Natural (Words.Length) = 1
                 and then Words.First_Element = "--describe"
                 and then Asked.Within = 10.0
                 and then Asked.Capture = Landin.Platform.Output_Only,
               "it is asked to describe itself within ten seconds first");
         end;
      end;

      --  A shipped command that is missing is never looked for on PATH.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         Install (Host);
         Tools.Add_Path_Program ("/usr/bin/refine-probe");
         Refused
           (Landin.Commands.Execute
              (["probe"], Host, Tools, Meter, Shipped => "probe"),
            "L0694", [Shipped_Path, "reinstall the release"],
            "a missing shipped command");
         Landin.Testing.Check
           (Item, Tools.Run_Count = 0,
            "a missing shipped command runs nothing, not PATH's copy");
      end;

      --  A contributed command: the first directory on the path wins.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Tools.Add_Path_Program ("/first/refine-lint");
         Tools.Add_Path_Program ("/second/refine-lint");
         Tools.Set_Result (0, Description ("lint", Q & "LNT" & Q, ""));
         Result := Landin.Commands.Execute
           (["lint", "x.ldn"], Host, Tools, Meter, Shipped => "probe");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Launch_Program),
            "/first/refine-lint",
            "a contributed command is the first one on the path");
      end;

      --  A name found nowhere is the unknown command it was (D1463).
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Result := Landin.Commands.Execute
           (["nonesuch"], Host, Tools, Meter, Shipped => "probe");
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Result.Report),
                                 "error[L0002]: unknown command: nonesuch"),
            "a name nothing answers is an unknown command: "
            & US.To_String (Result.Report));
      end;

      --  D1387's refusals, each with what came back and what to do.
      declare
         procedure Incompatible
           (Name : String; Shipped : Boolean; Exit_Code : Integer;
            Output : String; Needles : Landin.Platform.Path_List;
            What : String;
            Ended : Landin.Platform.Termination := Landin.Platform.Exited);
         procedure Incompatible
           (Name : String; Shipped : Boolean; Exit_Code : Integer;
            Output : String; Needles : Landin.Platform.Path_List;
            What : String;
            Ended : Landin.Platform.Termination := Landin.Platform.Exited)
         is
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         begin
            Install (Host);
            if Shipped then
               Host.Add_File
                 ("/opt/landin/libexec/landin/refine-" & Name, "");
            else
               Tools.Add_Path_Program ("/usr/bin/refine-" & Name);
            end if;
            Tools.Set_Result (Exit_Code, Output, Ended);
            Refused
              (Landin.Commands.Execute
                 ([Name], Host, Tools, Meter,
                  Shipped => (if Shipped then Name else "")),
               "L0695", Needles, What);
         end Incompatible;
         Other : constant String (1 .. 64) := [others => 'b'];
      begin
         Incompatible
           ("probe", True, 0, Description ("probe", Digest => Other),
            ["refine-probe --describe",
             "built from compiler sources bbbbbbbbbbbb",
             "reinstall the release"],
            "a shipped command of another digest");
         Incompatible
           ("probe", True, 2, "",
            ["exited with status 2", "rebuild both from one checkout"],
            "a shipped command without a description");
         Incompatible
           ("probe", True, 0, Description ("probe", Digest => ""),
            ["has no ""source_digest"" string"],
            "a shipped command that names no digest");
         Incompatible
           ("probe", True, 0, Description ("probe", Q & "PRB" & Q),
            ["claims the code prefix PRB"],
            "a shipped command claiming a prefix");
         Incompatible
           ("lint", False, 0, Description ("lint", Q & "L" & Q, ""),
            ["claims L", "update or remove it, or run it by its own name"],
            "a contributed command claiming L");
         Incompatible
           ("lint", False, 0, "not json",
            ["its answer is not JSON"], "an answer that is not JSON");
         Incompatible
           ("lint", False, 0, Description ("other", Digest => ""),
            ["names itself other"], "a command naming another");
         Incompatible
           ("lint", False, 0,
            Description ("lint", Digest => "", Format => "landin-command-2"),
            ["format landin-command-2", "reads landin-command-1"],
            "a newer format");
         Incompatible
           ("lint", False, 0, "", ["did not answer within 10 seconds"],
            "a command that does not answer",
            Ended => Landin.Platform.Timed_Out);
      end;

      --  D1385: a code of another prefix goes to the one contributed
      --  command claiming it, after a line saying whose it is.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Tools.Add_Path_Program ("/usr/bin/refine-lint");
         Tools.Set_Result (0, Description ("lint", Q & "LNT" & Q, ""));
         Result := Landin.Commands.Execute
           (["explain", "LNT0042"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, US.To_String (Result.Launch_Program)
                = "/usr/bin/refine-lint"
              and then Natural (Result.Launch_Arguments.Length) = 2
              and then Result.Launch_Arguments (1) = "explain"
              and then Result.Launch_Arguments (2) = "LNT0042"
              and then US.To_String (Result.Output)
                = "LNT0042 is explained by refine-lint at"
                  & " /usr/bin/refine-lint, not by Landin" & ASCII.LF,
            "a claimed code is forwarded: "
            & US.To_String (Result.Output) & US.To_String (Result.Report));
         Result := Landin.Commands.Execute
           (["explain", "XYZ0042"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Result.Report),
                                 "no refine-NAME command on PATH claims it"),
            "a prefix no command claims is refused: "
            & US.To_String (Result.Report));
         Result := Landin.Commands.Execute
           (["explain", "L9999"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then US.Length (Result.Launch_Program) = 0,
            "an L code outside the catalogue is unknown, never forwarded");
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Tools.Add_Path_Program ("/usr/bin/refine-aa");
         Tools.Add_Path_Program ("/usr/bin/refine-bb");
         Tools.Add_Result (0, Description ("aa", Q & "DUP" & Q, ""));
         Tools.Add_Result (0, Description ("bb", Q & "DUP" & Q, ""));
         Result := Landin.Commands.Execute
           (["explain", "DUP1"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Result.Report),
                                 "refine-aa at /usr/bin/refine-aa,"
                                 & " refine-bb at /usr/bin/refine-bb")
              and then Contains (US.To_String (Result.Report),
                                 "refine-NAME explain DUP1"),
            "a prefix two commands claim is refused naming both: "
            & US.To_String (Result.Report));
      end;

      --  Help lists external commands under their own heading, and an
      --  external command's help is its own (D1488).
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Tools.Add_Path_Program ("/usr/bin/refine-lint");
         Tools.Add_Path_Program ("/usr/bin/refine-check");
         Tools.Add_Path_Program ("/usr/bin/refine-probe");
         Tools.Set_Result (0, Description ("lint", Digest => ""));
         Result := Landin.Commands.Execute
           (["help"], Host, Tools, Meter, Shipped => "probe");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Output),
                            ASCII.LF & "External commands:" & ASCII.LF
                            & "  probe       missing: " & Shipped_Path
                            & ASCII.LF
                            & "  lint        the lint tool"
                            & " (/usr/bin/refine-lint)" & ASCII.LF)
              and then not Contains (US.To_String (Result.Output),
                                     "refine-check"),
            "help lists the external commands: "
            & US.To_String (Result.Output));
         Result := Landin.Commands.Execute
           (["help", "lint"], Host, Tools, Meter, Shipped => "probe");
         Landin.Testing.Check
           (Item, US.To_String (Result.Launch_Program)
                = "/usr/bin/refine-lint"
              and then Natural (Result.Launch_Arguments.Length) = 1
              and then Result.Launch_Arguments (1) = "--help",
            "help NAME runs refine-NAME --help");
      end;

      --  D1603: `build` is a contributed refine-build's, dispatched,
      --  listed, helped, explained and completed as any contributed
      --  command is; with none on the path it is refused saying so.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Tools.Add_Path_Program ("/usr/bin/refine-build");
         Tools.Set_Result (0, Description ("build", Q & "RB" & Q, ""));
         Result := Landin.Commands.Execute
           (["build", "--release", "app"], Host, Tools, Meter,
            Shipped => "probe");
         Landin.Testing.Check
           (Item, US.To_String (Result.Launch_Program)
                = "/usr/bin/refine-build"
              and then Natural (Result.Launch_Arguments.Length) = 2
              and then Result.Launch_Arguments (1) = "--release"
              and then Result.Launch_Arguments (2) = "app"
              and then US.To_String (Result.Launch_Setting)
                = "LANDIN_REFINE=/opt/landin/bin/refine",
            "refine build runs a contributed refine-build: "
            & US.To_String (Result.Report));
         Result := Landin.Commands.Execute
           (["help"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Output),
                            "  build       the build tool"
                            & " (/usr/bin/refine-build)" & ASCII.LF),
            "help lists a contributed refine-build: "
            & US.To_String (Result.Output));
         Result := Landin.Commands.Execute
           (["help", "build"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, US.To_String (Result.Launch_Program)
                = "/usr/bin/refine-build"
              and then Natural (Result.Launch_Arguments.Length) = 1
              and then Result.Launch_Arguments (1) = "--help",
            "help build runs refine-build --help");
         Result := Landin.Commands.Execute
           (["explain", "RB0003"], Host, Tools, Meter, Shipped => "");
         Landin.Testing.Check
           (Item, US.To_String (Result.Launch_Program)
                = "/usr/bin/refine-build"
              and then Natural (Result.Launch_Arguments.Length) = 2
              and then Result.Launch_Arguments (1) = "explain"
              and then Result.Launch_Arguments (2) = "RB0003",
            "a code refine-build claims is forwarded to it: "
            & US.To_String (Result.Report));
         Result := Landin.Commands.Execute
           (["build", "--complete", "--", ""], Host, Tools, Meter,
            Shipped => "");
         Landin.Testing.Check
           (Item, US.To_String (Result.Launch_Program)
                = "/usr/bin/refine-build",
            "refine-build completes its own words");
      end;
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Result := Landin.Commands.Execute
           (["build", "app"], Host, Tools, Meter, Shipped => "probe");
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then US.Length (Result.Launch_Program) = 0
              and then Contains (US.To_String (Result.Report),
                                 "error[L0002]: refine has no build command"
                                 & " of its own: refine build runs a"
                                 & " contributed refine-build, and none is"
                                 & " on PATH"),
            "refine build without a refine-build says so: "
            & US.To_String (Result.Report));
         Result := Landin.Commands.Execute
           (["help", "build"], Host, Tools, Meter, Shipped => "probe");
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Result.Report),
                                 "error[L0002]: refine has no build"),
            "help build without a refine-build says so: "
            & US.To_String (Result.Report));
      end;

      --  D1487: version describes the installation it runs from.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Result : Landin.Driver.Outcome;
      begin
         Install (Host);
         Host.Add_Directory ("/opt/landin/lib/landin/core");
         Host.Add_File (Shipped_Path, "");
         Tools.Set_Result (0, Description ("probe"));
         Result := Landin.Commands.Execute
           (["version"], Host, Tools, Meter, Shipped => "probe absent");
         Landin.Testing.Check
           (Item, Contains (US.To_String (Result.Output),
                            "citations: /opt/landin/lib/landin/citations.txt,"
                            & " not there" & ASCII.LF
                            & "split command probe: " & Shipped_Path
                            & ASCII.LF
                            & "split command absent: missing,"
                            & " /opt/landin/libexec/landin/refine-absent"
                            & ASCII.LF),
            "version names the citations and the split commands: "
            & US.To_String (Result.Output));
      end;

      --  D1485: completion hands an external command's words to it.
      Landin.Testing.Check
        (Item, Contains (Landin.Commands.Catalogue.Shell_Completion ("bash"),
                         "--complete --")
           and then Contains
             (Landin.Commands.Catalogue.Shell_Completion ("zsh"),
              "--complete --")
           and then Contains
             (Landin.Commands.Catalogue.Shell_Completion ("fish"),
              "--complete --"),
         "every shell's completion delegates to refine-NAME --complete");
      Landin.Testing.Check
        (Item, not Contains
                 (Landin.Commands.Catalogue.Shell_Completion ("bash"),
                  "|build")
           and then Contains
             (Landin.Commands.Catalogue.Shell_Completion ("bash"),
              "|help) ;;")
           and then not Contains
             (Landin.Commands.Catalogue.Shell_Completion ("fish"),
              " help build"),
         "no completion script keeps build from a refine-build (D1603)");
   end Dispatcher;

   --  D1485, D1544: each split command answers its process surface
   --  itself, and keeps the shared options and response files a built-in
   --  command takes; D1545: an option before a split's name is refine's.
   procedure Split_Surface (Item : in out Landin.Testing.Context);
   procedure Split_Surface (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;

      type Split is (Svd, Bindings, Site);

      function Run (Command : Split; Words : Landin.Platform.Path_List)
        return Landin.Driver.Outcome is
        (case Command is
            when Svd => Landin.Splits.Svd.Execute (Words, Host, Tools),
            when Bindings => Landin.Splits.Bindings.Execute
              (Words, Host, Tools, "x86_64-pc-linux-gnu"),
            when Site => Landin.Splits.Site.Execute (Words, Host, Tools));

      function Name (Command : Split) return String is
        (case Command is
            when Svd => "svd", when Bindings => "bindings",
            when Site => "site");

      function Own_Option (Command : Split) return String is
        (case Command is
            when Svd => "--policy", when Bindings => "--clang",
            when Site => "--map");
   begin
      Host.Add_File ("words", "--policy=toy.json" & ASCII.LF);
      for Command in Split loop
         declare
            Said : constant Landin.Driver.Outcome :=
              Run (Command, ["--describe"]);
            Text : constant String := US.To_String (Said.Output);
         begin
            Landin.Testing.Check
              (Item, Said.Status = 0
                 and then Contains (Text, """format"":""landin-command-1""")
                 and then Contains (Text, """name"":""" & Name (Command)
                                    & """")
                 and then Contains (Text, """source_digest"":"""
                   & Landin.Build_Identity.Source_Digest & """")
                 and then Contains (Text, """codes"":[]"),
               Name (Command) & " describes itself as shipped: " & Text);
         end;
         declare
            Said : constant Landin.Driver.Outcome :=
              Run (Command, ["--help"]);
            Text : constant String := US.To_String (Said.Output);
         begin
            Landin.Testing.Check
              (Item, Said.Status = 0
                 and then Text'Length > 0
                 and then Contains (Text, "usage: refine " & Name (Command)
                                    & " ")
                 and then Contains (Text, Own_Option (Command))
                 and then Contains (Text, "--diagnostics"),
               Name (Command) & " prints its own help: " & Text);
         end;
         declare
            Said : constant Landin.Driver.Outcome :=
              Run (Command, ["--complete", "--",
                             Own_Option (Command) (1 .. 4)]);
            Text : constant String := US.To_String (Said.Output);
         begin
            Landin.Testing.Check
              (Item, Said.Status = 0
                 and then Contains (Text, Own_Option (Command) & ASCII.LF),
               Name (Command) & " completes its own options: " & Text);
         end;
         declare
            Said : constant Landin.Driver.Outcome :=
              Run (Command, ["--colour=never", "x"]);
            Text : constant String := US.To_String (Said.Report);
         begin
            Landin.Testing.Check
              (Item, Said.Status = Landin.Driver.Status_Misuse
                 and then Contains (Text, "error[L0002]: unknown option:"
                   & " --colour=never; did you mean --color?"),
               Name (Command) & " refuses an unknown option: " & Text);
         end;
         declare
            Said : constant Landin.Driver.Outcome :=
              Run (Command, ["--diagnostics=json", "--color=never"]);
            Text : constant String := US.To_String (Said.Report);
         begin
            Landin.Testing.Check
              (Item, Said.Status = Landin.Driver.Status_Misuse
                 and then Contains (Text, """severity"":""error""")
                 and then Contains (Text, "L0002"),
               Name (Command) & " presents a refusal as --diagnostics asks: "
               & Text);
         end;
      end loop;
      --  A response file is read as before the split.
      declare
         Said : constant Landin.Driver.Outcome :=
           Run (Svd, ["@words", "toy.svd"]);
      begin
         Landin.Testing.Check
           (Item, Said.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Said.Report),
                "svd needs the policy the SVD was reviewed against"),
            "svd reads its response file: " & US.To_String (Said.Report));
      end;
      declare
         Said : constant Landin.Driver.Outcome :=
           Run (Svd, ["--policy=a", "--policy=b", "--out-dir=o", "x.svd"]);
      begin
         Landin.Testing.Check
           (Item, Said.Status = Landin.Driver.Status_Misuse
              and then Contains (US.To_String (Said.Report),
                "--policy may be given once"),
            "a single option is given once: " & US.To_String (Said.Report));
      end;
      --  D1545: `refine --quiet svd ...` is told its form with the name
      --  first, and nothing is run.
      declare
         Said : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute
             (["--quiet", "svd", "--policy=p.json", "x.svd"], Host, Tools,
              Meter, Shipped => "bindings site svd");
      begin
         Landin.Testing.Check
           (Item, Said.Status = Landin.Driver.Status_Misuse
              and then Tools.Run_Count = 0
              and then Contains (US.To_String (Said.Report),
                "an option before svd is refine's own, and svd takes its"
                & " options after its name: refine svd --quiet"
                & " --policy=p.json x.svd"),
            "an option before a split's name is placed after it: "
            & US.To_String (Said.Report));
      end;
   end Split_Surface;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "commands", "actionable command guidance",
         Actionable_Command_Guidance'Access);
      Landin.Testing.Register
        (Into, "commands", "site is a subcommand",
         Site_Is_A_Subcommand'Access);
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
      Landin.Testing.Register
        (Into, "commands", "response inputs survive publication",
         Response_Inputs_Survive'Access);
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
        (Into, "commands", "the bare form is refused",
         Bare_Form_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "commands", "-L names a library directory",
         Library_Directory_Option'Access);
      Landin.Testing.Register (Into, "commands", "diagnostic presentation",
                              Presentation'Access);
      Landin.Testing.Register
        (Into, "commands", "the help reference is recorded",
         Reference_Is_Recorded'Access);
      Landin.Testing.Register
        (Into, "commands", "the dispatcher", Dispatcher'Access);
      Landin.Testing.Register
        (Into, "commands", "a split answers its own surface",
         Split_Surface'Access);
   end Register;
end Landin.Tests.Commands_Suite;
