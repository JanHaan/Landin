with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend.Toolchain;
with Landin.Diagnostics;
with Landin.Driver;
with Landin.Platform;
with Landin.Targets;
with Landin.Testing.Fakes;

package body Landin.Tests.Newcomer_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   --  The compiler's own host in every case, so the answers do not depend
   --  on the machine the test program runs on.
   Linux_Host : constant String := "x86_64-pc-linux-gnu";

   Entry_Program : constant String :=
     "public main: () -> (code: i32) =" & LF
     & "    code = 42" & LF
     & "end main" & LF;

   --  The least library a static Linux link needs: platform/linux's entry.
   procedure Add_Library (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

   procedure Add_Library
     (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
   begin
      Host.Add_Directory ("lib");
      Host.Add_Directory ("lib/platform");
      Host.Add_Directory ("lib/platform/linux");
      Host.Add_File
        ("lib/platform/linux/linux.ldn",
         "fixed if compiler.os == linux then" & LF
         & "    public extern(naked) _landin_start: () -> none =" & LF
         & "        assembler.block(""ud2"")" & LF
         & "    end _landin_start" & LF
         & "end if" & LF);
   end Add_Library;

   function Run
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Testing.Fakes.Fake_Filesystem;
      Tools     : Landin.Testing.Fakes.Fake_Tool_Runner;
      Dry_Run   : Boolean := False) return Landin.Driver.Outcome;

   function Run
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Testing.Fakes.Fake_Filesystem;
      Tools     : Landin.Testing.Fakes.Fake_Tool_Runner;
      Dry_Run   : Boolean := False) return Landin.Driver.Outcome
   is
      Nothing : Landin.Platform.Unmetered;
   begin
      return Landin.Driver.Execute
        (Arguments, Host, Tools, Nothing, Built_For => Linux_Host,
         Dry_Run => Dry_Run);
   end Run;

   function Report (Of_Outcome : Landin.Driver.Outcome) return String
     is (Unbounded.To_String (Of_Outcome.Report));

   ---------------------------------------------------------------------
   --  D364: the drivers a link may use
   ---------------------------------------------------------------------

   procedure Linux_Names_Every_Distribution_Driver
     (Item : in out Landin.Testing.Context);

   procedure Linux_Names_Every_Distribution_Driver
     (Item : in out Landin.Testing.Context)
   is
      function Listed (Facts : Landin.Targets.Target_Facts;
                       Named : String; Native : Boolean) return String
        is (Landin.Platform.Joined
              (Landin.Backend.Toolchain.Driver_Candidates
                 (Facts, Named, Native)));
   begin
      Landin.Testing.Check_Equal
        (Item, Listed (Landin.Targets.Linux_X86_64, "", True),
         "x86_64-pc-linux-gnu-gcc" & LF & "x86_64-linux-gnu-gcc" & LF
         & "x86_64-redhat-linux-gcc" & LF & "gcc" & LF,
         "the pinned name, Debian's, Fedora's and the host's own gcc");
      Landin.Testing.Check_Equal
        (Item, Listed (Landin.Targets.Linux_Arm64, "", False),
         "aarch64-linux-gnu-gcc" & LF & "aarch64-redhat-linux-gcc" & LF
         & "aarch64-unknown-linux-gnu-gcc" & LF,
         "a cross target never falls back to the host's gcc");
      Landin.Testing.Check_Equal
        (Item, Listed (Landin.Targets.Linux_X86_64, "my-gcc", True),
         "my-gcc" & LF, "a named driver is the only one tried");
      Landin.Testing.Check_Equal
        (Item, Listed (Landin.Targets.Darwin_Arm64, "", True),
         "/usr/bin/clang" & LF, "Darwin keeps Apple's driver alone");
      Landin.Testing.Check
        (Item, Contains
           (Landin.Backend.Toolchain.Install_Advice
              (Landin.Targets.Linux_Arm64, "", False),
            "apt install gcc-aarch64-linux-gnu"),
         "a cross target is told which cross compiler to install");
   end Linux_Names_Every_Distribution_Driver;

   procedure A_Stock_Driver_Links (Item : in out Landin.Testing.Context);

   procedure A_Stock_Driver_Links (Item : in out Landin.Testing.Context) is
      procedure Linked_By (Absent : Landin.Platform.Path_List;
                           Expected : String);
      procedure Linked_By (Absent : Landin.Platform.Path_List;
                           Expected : String)
      is
         Host  : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         Host.Add_File ("main.ldn", Entry_Program);
         Add_Library (Host);
         for Name of Absent loop
            Tools.Set_Absent (Name);
         end loop;
         declare
            Result : constant Landin.Driver.Outcome := Run
              (["--target=linux-x86-64", "--library=lib", "main.ldn",
                "--emit=exe", "-o", "main"], Host, Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               "links with " & Expected & ": " & Report (Result));
            Landin.Testing.Check
              (Item, Tools.Run_Count = 1 and then Unbounded.To_String
                 (Tools.Call_At (1).Program) = Expected,
               "the link runs " & Expected);
         end;
      end Linked_By;
   begin
      Linked_By (["x86_64-pc-linux-gnu-gcc"], "x86_64-linux-gnu-gcc");
      Linked_By (["x86_64-pc-linux-gnu-gcc", "x86_64-linux-gnu-gcc"],
                 "x86_64-redhat-linux-gcc");
      Linked_By (["x86_64-pc-linux-gnu-gcc", "x86_64-linux-gnu-gcc",
                  "x86_64-redhat-linux-gcc"], "gcc");
   end A_Stock_Driver_Links;

   procedure A_Missing_Driver_Says_What_To_Install
     (Item : in out Landin.Testing.Context);

   procedure A_Missing_Driver_Says_What_To_Install
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      Tools.Set_Available (False);
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=linux-arm64", "--link=libc", "main.ldn",
             "--emit=exe", "-o", "main"], Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Reported,
            "the missing driver is refused");
         Landin.Testing.Check
           (Item, Contains (Report (Result),
              "error[L0500]: no compiler driver to link linux-arm64 was"
              & " found; looked for aarch64-linux-gnu-gcc,"
              & " aarch64-redhat-linux-gcc and aarch64-unknown-linux-gnu-gcc")
            and then Contains (Report (Result),
              "apt install gcc-aarch64-linux-gnu")
            and then Contains (Report (Result), "--toolchain=NAME"),
            "it names what was looked for and what to install: "
            & Report (Result));
         Landin.Testing.Check
           (Item, Tools.Run_Count = 0 and then Host.Write_Count = 0,
            "nothing is written and nothing runs");
      end;
   end A_Missing_Driver_Says_What_To_Install;

   --  D364: the program's own refusal comes before the toolchain's.
   procedure A_Static_Refusal_Precedes_A_Missing_Driver
     (Item : in out Landin.Testing.Context);

   procedure A_Static_Refusal_Precedes_A_Missing_Driver
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File
        ("main.ldn",
         "extern(c) puts: (text: ptr u8) -> (result: i32)" & LF & LF
         & "greeting: [3]u8 = [104, 105, 0]" & LF & LF
         & "public main: () -> (code: i32) =" & LF
         & "    _ = puts(addr greeting[0])" & LF
         & "    code = 0" & LF & "end main" & LF);
      Add_Library (Host);
      Tools.Set_Available (False);
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--library=lib", "main.ldn",
             "--emit=exe", "-o", "main"], Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Contains (Report (Result),
              "has no C library to define `puts`")
            and then not Contains (Report (Result), "compiler driver"),
            "the static link's refusal comes first, alone: "
            & Report (Result));
         Landin.Testing.Check_Equal
           (Item, Host.Write_Count, 0, "nothing is written");
      end;
   end A_Static_Refusal_Precedes_A_Missing_Driver;

   ---------------------------------------------------------------------
   --  D362: the intermediate assembly, and an assembly operand
   ---------------------------------------------------------------------

   procedure Assembly_Is_Kept_Only_On_Request
     (Item : in out Landin.Testing.Context);

   procedure Assembly_Is_Kept_Only_On_Request
     (Item : in out Landin.Testing.Context)
   is
      procedure Compile (Extra : String; Kept : Boolean);
      procedure Compile (Extra : String; Kept : Boolean) is
         Host  : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args  : Landin.Platform.Path_List :=
           ["--target=linux-x86-64", "--library=lib", "main.ldn",
            "--emit=exe", "-o", "main"];
      begin
         Host.Add_File ("main.ldn", Entry_Program);
         Add_Library (Host);
         if Extra /= "" then
            Args.Append (Extra);
         end if;
         declare
            Result : constant Landin.Driver.Outcome := Run (Args, Host, Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               "compiles with '" & Extra & "': " & Report (Result));
            Landin.Testing.Check
              (Item, Host.Written ("main.s") /= "",
               "the link read the assembly it was given");
            Landin.Testing.Check
              (Item, Host.Exists ("main.s") = Kept,
               "with '" & Extra & "' the assembly is "
               & (if Kept then "kept" else "removed"));
         end;
      end Compile;

      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Compile ("", Kept => False);
      Compile ("--keep-asm", Kept => True);
      --  A source map names the assembly it was made with.
      Compile ("--panic-map", Kept => True);

      Host.Add_File ("main.ldn", Entry_Program);
      Add_Library (Host);
      declare
         Planned : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--library=lib", "main.ldn",
             "--emit=exe", "-o", "main"], Host, Tools, Dry_Run => True);
         Refused : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--library=lib", "main.ldn",
             "--emit=asm", "--keep-asm", "-o", "main.s"], Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Contains (Unbounded.To_String (Planned.Output),
              "remove ""main.s""" & LF),
            "a dry run says the assembly is removed: "
            & Unbounded.To_String (Planned.Output));
         Landin.Testing.Check
           (Item, Refused.Status = Landin.Driver.Status_Misuse
              and then Contains (Report (Refused), "--keep-asm keeps an"
                                 & " executable's assembly"),
            "--keep-asm without an executable is a misuse: "
            & Report (Refused));
      end;
   end Assembly_Is_Kept_Only_On_Request;

   procedure An_Assembly_Operand_Links
     (Item : in out Landin.Testing.Context);

   procedure An_Assembly_Operand_Links
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("hand.s", "# edited by hand" & LF);
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "hand.s", "--emit=exe", "-o", "hand"],
            Host, Tools);
         Speed : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--optimize=speed", "hand.s",
             "--emit=exe", "-o", "hand"], Host, Tools);
         Asm : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "hand.s", "--emit=asm", "-o",
             "other.s"], Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "the operand links: " & Report (Result));
         if Tools.Run_Count >= 1 then
            Landin.Testing.Check_Equal
              (Item, Landin.Platform.Joined (Tools.Call_At (1).Arguments),
               "-nostdlib" & LF & "-static" & LF & "-no-pie" & LF
               & "-Wl,-e,_landin_start" & LF & "hand.s" & LF & "-o" & LF
               & "hand" & LF & "-Wl,--gc-sections" & LF
               & "-Wa,-march=generic64" & LF,
               "with the link a compiled program's static link has");
         end if;
         Landin.Testing.Check
           (Item, Host.Exists ("hand.s"), "the operand is the user's, kept");
         Landin.Testing.Check
           (Item, Speed.Status = Landin.Driver.Status_Misuse
              and then Contains (Report (Speed), "--optimize describes"
                                 & " compiling Landin source"),
            "a compilation option is refused with an operand: "
            & Report (Speed));
         Landin.Testing.Check
           (Item, Asm.Status = Landin.Driver.Status_Misuse,
            "--emit=asm of an assembly operand is a misuse: "
            & Report (Asm));
      end;
   end An_Assembly_Operand_Links;

   ---------------------------------------------------------------------
   --  D365: the IR the backend receives
   ---------------------------------------------------------------------

   procedure The_IR_Is_Written_On_Request
     (Item : in out Landin.Testing.Context);

   procedure The_IR_Is_Written_On_Request
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Entry_Program);
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--link=libc", "main.ldn",
             "--emit=ir", "-o", "main.ir"], Host, Tools);
         Debugged : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--link=libc", "main.ldn",
             "--emit=ir", "--debug=full", "-o", "other.ir"], Host, Tools);
         Dump : constant String := Host.Written ("main.ir");
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "the IR is written: " & Report (Result));
         Landin.Testing.Check
           (Item, Dump'Length > 5
              and then Dump (Dump'First .. Dump'First + 4) = "unit "
              and then Contains (Dump, "main"),
            "in Landin.IR.Dump's text: " & Dump);
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "no tool runs");
         Landin.Testing.Check
           (Item, Debugged.Status = Landin.Driver.Status_Misuse,
            "--debug with --emit=ir is a misuse: " & Report (Debugged));
      end;
   end The_IR_Is_Written_On_Request;

   ---------------------------------------------------------------------
   --  D361: the hosted default's report
   ---------------------------------------------------------------------

   Trapping_Library : constant String :=
     "public at: (i: usize) -> (r: u32) =" & LF
     & "    values: [2]u32 = [1, 2]" & LF
     & "    r = values[i]" & LF
     & "end at" & LF;

   Trapping_Program : constant String :=
     "import core/t" & LF & LF
     & "public main: () -> (code: i32) =" & LF
     & "    code = i32(t.at(5))" & LF
     & "end main" & LF;

   procedure A_Trap_Names_Its_Site (Item : in out Landin.Testing.Context);

   procedure A_Trap_Names_Its_Site (Item : in out Landin.Testing.Context) is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_File ("main.ldn", Trapping_Program);
      Host.Add_Directory ("lib");
      Host.Add_Directory ("lib/core");
      Host.Add_Directory ("lib/core/t");
      Host.Add_File ("lib/core/t/t.ldn", Trapping_Library);
      for Optimize in 1 .. 3 loop
         declare
            Level : constant String :=
              (case Optimize is when 1 => "none", when 2 => "size",
                  when others => "speed");
            Output : constant String := "out-" & Level & ".s";
            Result : constant Landin.Driver.Outcome := Run
              (["--target=linux-x86-64", "--link=libc", "--library=lib",
                "--optimize=" & Level, "main.ldn", "--emit=asm", "-o",
                Output], Host, Tools);
            Text : constant String := Host.Written (Output);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               Level & " emits: " & Report (Result));
            --  The library's file by its module path, wherever the
            --  library is, at the indexing's own line and column.
            Landin.Testing.Check
              (Item, Contains (Text, ".asciz ""core/t/t.ldn:3:9: trap:"
                               & " out_of_range\012""")
                 and then Contains (Text, "landin_trap_report"),
               Level & ": the report names the library file and its site");
         end;
      end loop;
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=cortex-m0", "--library=lib", "main.ldn",
             "--emit=asm", "-o", "firmware.s"], Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Success
              and then not Contains (Host.Written ("firmware.s"), ": trap: ")
              and then not Contains
                (Host.Written ("firmware.s"), "landin_trap_report"),
            "firmware keeps its bare terminal instruction: "
            & Report (Result));
      end;
   end A_Trap_Names_Its_Site;

   ---------------------------------------------------------------------
   --  Finding the library: D363 and D366
   ---------------------------------------------------------------------

   procedure A_Library_Found_Nowhere_Says_Where_It_Looked
     (Item : in out Landin.Testing.Context);

   procedure A_Library_Found_Nowhere_Says_Where_It_Looked
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Set_Executable_Directory ("/opt/landin/bin");
      Host.Add_File
        ("main.ldn", "import core/io" & LF & LF & Entry_Program);
      Host.Add_File ("plain.ldn", Entry_Program);
      declare
         Checked : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "main.ldn"], Host, Tools);
         Emitted : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "plain.ldn", "--emit=asm", "-o",
             "plain.s"], Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Contains (Report (Checked),
              "module `core/io` is in refine's library, and no library was"
              & " found: refine looked in /opt/landin/lib/landin")
            and then Contains (Report (Checked), "--library=DIR")
            and then not Contains (Report (Checked), "--root=DIR"),
            "the import names where refine looked and --library: "
            & Report (Checked));
         Landin.Testing.Check
           (Item, Emitted.Status = Landin.Driver.Status_Reported
              and then Contains (Report (Emitted),
                "no library holding platform/linux was found")
              and then Host.Written ("plain.s") = "",
            "static assembly without platform/linux is refused, not"
            & " written without it: " & Report (Emitted));
      end;
   end A_Library_Found_Nowhere_Says_Where_It_Looked;

   procedure A_Misspelt_Namespace_Is_Offered_The_Library
     (Item : in out Landin.Testing.Context);

   procedure A_Misspelt_Namespace_Is_Offered_The_Library
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      Host.Add_Directory ("lib");
      Host.Add_Directory ("lib/core");
      Host.Add_Directory ("lib/core/io");
      Host.Add_File ("lib/core/io/io.ldn", Trapping_Library);
      Host.Add_File
        ("main.ldn", "import cor/io" & LF & LF & Entry_Program);
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--library=lib", "main.ldn"],
            Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Contains (Report (Result),
              "error[L0006]: module `cor/io` is not found: no import root"
              & " was given")
            and then Contains (Report (Result), "`core`"),
            "named files are offered the library's namespace: "
            & Report (Result));
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Result.Found), 1,
            "in one report");
      end;
   end A_Misspelt_Namespace_Is_Offered_The_Library;

   procedure A_Root_Holding_The_Library_Is_Told
     (Item : in out Landin.Testing.Context);

   procedure A_Root_Holding_The_Library_Is_Told
     (Item : in out Landin.Testing.Context)
   is
      Host  : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
   begin
      for Tree in 1 .. 2 loop
         declare
            Top : constant String := (if Tree = 1 then "lib" else "proj");
         begin
            Host.Add_Directory (Top);
            Host.Add_Directory (Top & "/core");
            Host.Add_Directory (Top & "/core/t");
            Host.Add_File (Top & "/core/t/t.ldn", Trapping_Library);
         end;
      end loop;
      Host.Add_Directory ("proj/app");
      Host.Add_File ("proj/app/main.ldn", Trapping_Program);
      declare
         Result : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--library=lib", "--root=proj",
             "proj/app"], Host, Tools);
         Library : constant Landin.Driver.Outcome := Run
           (["--target=linux-x86-64", "--library=proj", "--root=proj",
             "proj/app"], Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Success
              and then Contains (Report (Result), "warning[L0016]")
              and then Contains (Report (Result), "--library=proj"),
            "the root's copy is named, with --library: " & Report (Result));
         Landin.Testing.Check
           (Item, not Contains (Report (Library), "L0016"),
            "a root that is the library is searched once, silently: "
            & Report (Library));
      end;
   end A_Root_Holding_The_Library_Is_Told;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "driver", "linux names every distribution's driver",
         Linux_Names_Every_Distribution_Driver'Access);
      Landin.Testing.Register
        (Into, "driver", "a stock driver links",
         A_Stock_Driver_Links'Access);
      Landin.Testing.Register
        (Into, "driver", "a missing driver says what to install",
         A_Missing_Driver_Says_What_To_Install'Access);
      Landin.Testing.Register
        (Into, "driver", "a static refusal precedes a missing driver",
         A_Static_Refusal_Precedes_A_Missing_Driver'Access);
      Landin.Testing.Register
        (Into, "driver", "assembly is kept only on request",
         Assembly_Is_Kept_Only_On_Request'Access);
      Landin.Testing.Register
        (Into, "driver", "an assembly operand links",
         An_Assembly_Operand_Links'Access);
      Landin.Testing.Register
        (Into, "driver", "the IR is written on request",
         The_IR_Is_Written_On_Request'Access);
      Landin.Testing.Register
        (Into, "driver", "a trap names its site",
         A_Trap_Names_Its_Site'Access);
      Landin.Testing.Register
        (Into, "driver", "a library found nowhere says where it looked",
         A_Library_Found_Nowhere_Says_Where_It_Looked'Access);
      Landin.Testing.Register
        (Into, "driver", "a misspelt namespace is offered the library",
         A_Misspelt_Namespace_Is_Offered_The_Library'Access);
      Landin.Testing.Register
        (Into, "driver", "a root holding the library is told",
         A_Root_Holding_The_Library_Is_Told'Access);
   end Register;

end Landin.Tests.Newcomer_Suite;
