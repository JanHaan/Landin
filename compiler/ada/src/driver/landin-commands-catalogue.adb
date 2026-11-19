with Ada.Strings.Fixed;
with Landin.Diagnostics.Suggestions;
with Landin.Diagnostics.Warning_Policy;

package body Landin.Commands.Catalogue is

   LF : constant Character := ASCII.LF;

   function Name (Command : Action) return String is
     (case Command is
         when Overview => "", when Check => "check",
         when Compile => "compile", when Run => "run",
         when Format => "fmt",
         when Explain => "explain",
         when Server => "lsp",
         when Version => "version", when Targets => "targets",
         when Completion => "completion", when Help => "help");

   function Description (Command : Action) return String is
     (case Command is
         when Overview => "The Landin bootstrap compiler",
         when Check => "Check a whole program without producing artifacts",
         when Compile =>
           "Compile a whole program to an executable or assembly",
         when Run =>
           "Compile a whole program to a temporary executable and run it",
         when Format =>
           "Format source files, or a directory's, in the one Landin layout",
         when Explain =>
           "Explain diagnostic codes, and the rules and decisions notes cite",
         when Server => "Serve the language server protocol over stdio",
         when Version => "Identify this compiler build",
         when Targets => "List described targets and their CPU feature levels",
         when Completion => "Print shell completion definitions",
         when Help => "Show help for a command or the complete CLI reference");

   function Known (Text : String) return Boolean is
     (Text /= "" and then
        (for some Command in Action => Name (Command) = Text));

   function Named (Text : String) return Action is
   begin
      for Command in Action loop
         if Name (Command) = Text then
            return Command;
         end if;
      end loop;
      raise Compiler_Defect with "unknown command passed to catalogue";
   end Named;

   function Name (Flag : Option) return String is
     (case Flag is
         when Help_Flag => "--help", when Verbose => "--verbose",
         when Quiet => "--quiet", when Color => "--color",
         when Diagnostics => "--diagnostics", when Target => "--target",
         when Level => "--level", when Root => "--root",
         when Library => "--library", when Library_Directory => "-L",
         when Build_Option => "--option", when Build_Mode => "--build-mode",
         when Optimize => "--optimize", when Specialize => "--specialize",
         when Emit => "--emit", when Output => "-o",
         when Keep_Asm => "--keep-asm", when Debug => "--debug",
         when Panic_Map => "--panic-map", when Toolchain => "--toolchain",
         when Linker => "--linker", when Link => "--link",
         when Firmware_Entry => "--firmware-entry",
         when Firmware_Layout => "--firmware-layout",
         when Linker_Script => "--linker-script",
         when Build_Report => "--build-report",
         when Stage_Report => "--stage-report", when Dry_Run => "--dry-run",
         when Stack_Report => "--stack-report",
         when Depfile => "--depfile", when Format_Check => "--check",
         when Format_Stdout => "--stdout", when Explain_Full => "--full",
         when Stdio => "--stdio", when JSON => "--json",
         when Warnings => "--warnings", when Warn => "--warn",
         when Allow => "--allow", when Deny => "--deny");

   function Description (Flag : Option) return String is
     (case Flag is
         when Help_Flag => "Print this command's help and exit",
         when Verbose =>
           "Describe the request and name the sources read; repeat to"
           & " trace tool commands",
         when Quiet => "Suppress progress, retaining warnings and errors",
         when Color => "Diagnostic color: auto (default), always, never",
         when Diagnostics =>
           "Diagnostic format on standard error: human (default), short, json",
         when Target => "Select a target; default is this compiler's host",
         when Level =>
           "CPU feature level whose instructions to use; default the baseline",
         when Root => "Append an ordered module import root (repeatable)",
         when Library =>
           "Where core, hosted and platform are; default beside refine",
         when Library_Directory =>
           "Search DIR for linker.library's libraries (repeatable)",
         when Build_Option => "Override a declared NAME=VALUE build option",
         when Build_Mode =>
           "compiler.build_mode: debug (default), release; not optimization",
         when Optimize =>
           "Code objective: none, size (default), speed",
         when Specialize =>
           "Direct evidence calls: off, auto (default, if worth it), all",
         when Emit =>
           "Artifact kind: exe (default), asm, ir, ir-annotated, "
           & "linker-script",
         when Output => "Output path; default a.out, a.s or a.ir",
         when Keep_Asm => "Keep an executable's assembly beside it as OUT.s",
         when Debug => "Debug information: none (default), full, lines",
         when Panic_Map => "Emit an off-target runtime check-site map",
         when Toolchain => "Override the target's native compiler driver",
         when Linker => "Select the native linker through that driver",
         when Link =>
           "Linux link: static (default) alone, or libc with C's runtime",
         when Firmware_Entry => "Select the firmware entry routine",
         when Firmware_Layout => "Firmware layout: boot (default), ram",
         when Linker_Script =>
           "Link firmware with FILE, checked against the contract",
         when Build_Report => "Write deterministic build evidence JSON",
         when Stage_Report => "Write stage CPU time and peak memory JSON",
         when Stack_Report =>
           "Write each emitted routine's frame and deepest stack JSON",
         when Dry_Run =>
           "Check and plan compilation; write and execute nothing",
         when Depfile =>
           "Write Make-format dependencies after successful emission",
         when Format_Check =>
           "Report every line out of the layout; write nothing",
         when Format_Stdout =>
           "Print the one source in the layout; write nothing",
         when Explain_Full =>
           "Add a construct's text or a decision's chosen rule",
         when Stdio => "Use the standard input/output LSP transport (default)",
         when JSON => "Print structured query output",
         when Warnings => "Base warning selection: default, all, none",
         when Warn => "Enable a warning code or all (repeatable)",
         when Allow => "Suppress a warning code or all (repeatable)",
         when Deny => "Enable and promote a warning to an error (repeatable)");

   function Values (Flag : Option) return String is
     (case Flag is
         when Warnings => "default|all|none",
         when Warn | Allow | Deny => "CODE|all",
         when Color => "auto|always|never",
         when Diagnostics => "human|short|json",
         when Firmware_Layout => "boot|ram",
         when Build_Mode => "debug|release",
         when Optimize => "none|size|speed",
         when Specialize => "off|auto|all",
         when Emit => "asm|exe|ir|ir-annotated|linker-script",
         when Debug => "none|full|lines", when Link => "static|libc",
         when others => "");

   function Takes_Value (Flag : Option) return Boolean is
     (Flag not in Help_Flag | Verbose | Quiet | Panic_Map | Dry_Run
       | Format_Check | Format_Stdout | Explain_Full | Stdio | JSON
       | Keep_Asm);

   function Shared (Flag : Option) return Boolean is
     (Flag in Help_Flag | Verbose | Quiet | Color | Diagnostics);

   function Accepts (Command : Action; Flag : Option) return Boolean is
     ((Shared (Flag) and then (Command /= Server or else Flag = Help_Flag))
      or else
      (case Command is
          --  D383: check takes every option that says what program is
          --  compiled and how, and none that says what is written.
          when Check => Flag in Target | Level | Root | Library
            | Library_Directory | Build_Option | Build_Mode | Optimize
            | Specialize | Link
            | Firmware_Entry | Firmware_Layout | Build_Report | Stage_Report
            | Warnings | Warn | Allow | Deny,
          when Compile => Flag in Target .. Depfile
            or else Flag in Warnings .. Deny,
          --  D526: compile's, except those that say what is written.
          when Run => (Flag in Target .. Depfile
                         and then Flag not in Emit | Output | Keep_Asm
                           | Dry_Run | Depfile)
            or else Flag in Warnings .. Deny,
          when Format => Flag in Format_Check | Format_Stdout,
          --  D1240: where the citations file is, as a compilation's.
          when Explain => Flag in Explain_Full | Library,
          when Server => Flag = Stdio,
          when Version => Flag in JSON | Library,
          when Targets => Flag = JSON,
          when others => False));

   function Owners (Flag : Option) return String is
      Text : US.Unbounded_String;
      Count : Natural := 0;
      Seen : Natural := 0;
   begin
      for Command in Action range Check .. Help loop
         if Accepts (Command, Flag) then
            Count := Count + 1;
         end if;
      end loop;
      for Command in Action range Check .. Help loop
         if Accepts (Command, Flag) then
            Seen := Seen + 1;
            US.Append (Text,
              (if Seen = 1 then ""
               elsif Seen = Count then " and "
               else ", ")
              & Name (Command));
         end if;
      end loop;
      return US.To_String (Text);
   end Owners;

   function First_Owner (Flag : Option) return Action is
   begin
      for Command in Action range Check .. Help loop
         if Accepts (Command, Flag) then
            return Command;
         end if;
      end loop;
      return Overview;
   end First_Owner;

   function Repeatable (Flag : Option) return Boolean is
     (Flag in Help_Flag | Verbose | Quiet | Root | Library_Directory
       | Build_Option | Warn | Allow | Deny);

   function Valid_Value (Flag : Option; Text : String) return Boolean is
   begin
      case Flag is
         when Warnings => return Text in "default" | "all" | "none";
         when Warn | Allow | Deny =>
            return Landin.Diagnostics.Warning_Policy.Valid_Selector (Text);
         when Color => return Text in "auto" | "always" | "never";
         when Diagnostics => return Text in "human" | "short" | "json";
         when Firmware_Layout => return Text in "boot" | "ram";
         when Build_Mode => return Text in "debug" | "release";
         when Optimize => return Text in "none" | "size" | "speed";
         when Specialize => return Text in "off" | "auto" | "all";
         when Emit =>
            return Text in "asm" | "exe" | "ir" | "ir-annotated"
              | "linker-script";
         when Debug => return Text in "none" | "full" | "lines";
         when Link => return Text in "static" | "libc";
         when others => return Text /= "";
      end case;
   end Valid_Value;

   function Known_Option (Text : String) return Boolean is
     (Text in "-h" | "-v" | "-q" | "--output" or else
      (for some Flag in Option => Name (Flag) = Text));

   function Named_Option (Text : String) return Option is
   begin
      if Text = "-h" then
         return Help_Flag;
      elsif Text = "-v" then
         return Verbose;
      elsif Text = "-q" then
         return Quiet;
      elsif Text = "--output" then
         return Output;
      end if;
      for Flag in Option loop
         if Name (Flag) = Text then
            return Flag;
         end if;
      end loop;
      raise Compiler_Defect with "unknown option passed to catalogue";
   end Named_Option;

   function Needs (Flag : Option) return Requirement is
     (case Flag is
         when Optimize | Specialize | Build_Report | Firmware_Entry
            | Firmware_Layout | Link =>
            A_Source,
         when Debug | Panic_Map | Stack_Report => Machine_Code,
         when Keep_Asm => An_Executable,
         when Output => An_Artifact,
         when others => Nothing);

   function Requirement_Problem
     (Flag : Option; Emitted : Emission; Has_Source : Boolean)
      return String is
     (case Needs (Flag) is
         when Nothing => "",
         when A_Source =>
           (if Has_Source then ""
            else Name (Flag) & " needs a source to compile"),
         when Machine_Code =>
           (if Emitted in Emit_Asm | Emit_Exe then ""
            elsif Emitted = Emit_IR
            then Name (Flag) & " describes machine code, and --emit=ir"
                 & " writes the IR before any is chosen"
            elsif Emitted = Emit_Linker_Script
            then Name (Flag) & " describes machine code, and"
                 & " --emit=linker-script writes a profile's script alone"
            else Name (Flag) & " describes emitted machine code: add"
                 & " --emit=asm or --emit=exe"),
         when An_Executable =>
           (if Emitted = Emit_Exe then ""
            else Name (Flag) & " describes an executable, which --emit=exe"
                 & " writes; --emit=asm writes the assembly alone"),
         when An_Artifact =>
           (if Emitted /= No_Emission then ""
            else Name (Flag) & " names what is emitted, and nothing is:"
                 & " add --emit=asm or --emit=exe"));

   function Compilation_Option (Flag : Option) return Boolean is
     (Accepts (Compile, Flag) and then not Shared (Flag)
      and then Flag not in Dry_Run | Depfile | Warnings .. Deny);

   function Given_Twice (Stem : String) return String is
     (Stem & " may be given once");

   --  "none, size or speed" for "none|size|speed".
   function Spoken (Choices : String) return String;

   function Spoken (Choices : String) return String is
      Last_Bar : constant Natural :=
        Ada.Strings.Fixed.Index (Choices, "|", Ada.Strings.Backward);
      Text : US.Unbounded_String;
   begin
      for Index in Choices'Range loop
         if Choices (Index) /= '|' then
            US.Append (Text, Choices (Index));
         elsif Index = Last_Bar then
            US.Append (Text, " or ");
         else
            US.Append (Text, ", ");
         end if;
      end loop;
      return US.To_String (Text);
   end Spoken;

   function Value_Choices (Flag : Option) return String is
     (if Values (Flag) = "" then ""
      else "; it takes " & Spoken (Values (Flag)));

   function Value_Problem (Flag : Option; Value : String) return String is
     (if Value = "" then Name (Flag) & " needs a value" & Value_Choices (Flag)
      else Name (Flag) & " does not take `" & Value & "`"
        & Value_Choices (Flag));

   function Nearest_Option (Stem : String) return String is
      Offered : Landin.Diagnostics.Suggestions.Ranking;
   begin
      --  What other compilers spell these, which no edit distance
      --  reaches.  A C compiler's `-g0` has no debug information and its
      --  `-g1` line tables alone; every other `-g` is the whole of it.
      if Stem in "--version" | "-v" | "-V" then
         return "--identify";
      elsif Stem = "-g0" then
         return "--debug=none";
      elsif Stem = "-g1" then
         return "--debug=lines";
      elsif Stem'Length >= 2
        and then Stem (Stem'First .. Stem'First + 1) = "-g"
      then
         return "--debug=full";
      elsif Stem in "--check" | "--format" then
         return "`refine fmt --check` (checking needs no option)";
      elsif Stem'Length >= 2
        and then Stem (Stem'First .. Stem'First + 1) = "-O"
      then
         return "--optimize";
      end if;
      Landin.Diagnostics.Suggestions.Consider (Offered, Stem, "--help");
      Landin.Diagnostics.Suggestions.Consider (Offered, Stem, "--identify");
      for Flag in Option loop
         if Compilation_Option (Flag) then
            Landin.Diagnostics.Suggestions.Consider
              (Offered, Stem, Name (Flag));
         end if;
      end loop;
      if Landin.Diagnostics.Suggestions.Count (Offered) > 0 then
         return Landin.Diagnostics.Suggestions.Nth (Offered, 1);
      end if;
      --  An option written as one word of a longer one, `--firmware` for
      --  `--firmware-entry` or `--entry` for it, is too far from it for an
      --  edit distance, and is offered every option it is a whole word of.
      declare
         Word : constant String :=
           (if Stem'Length > 2 and then Stem (Stem'First .. Stem'First + 1)
                 = "--"
            then Stem (Stem'First + 2 .. Stem'Last) else "");
         Found : Natural := 0;
         Text : US.Unbounded_String;
         Last : US.Unbounded_String;
      begin
         if Word'Length < 3 or else Ada.Strings.Fixed.Index (Word, "=") > 0
         then
            return "";
         end if;
         for Flag in Option loop
            declare
               Spelled : constant String := "-" & Name (Flag) & "-";
            begin
               if Compilation_Option (Flag) and then Found < 3
                 and then Spelled'Length > Word'Length + 4
                 and then Ada.Strings.Fixed.Index
                   (Spelled, "-" & Word & "-") > 0
               then
                  Found := Found + 1;
                  if Found > 1 then
                     US.Append
                       (Text, (if Found > 2 then ", " else "")
                        & US.To_String (Last));
                  end if;
                  Last := US.To_Unbounded_String (Name (Flag));
               end if;
            end;
         end loop;
         if Found = 0 then
            return "";
         elsif Found = 1 then
            return US.To_String (Last);
         end if;
         return US.To_String (Text) & " or " & US.To_String (Last);
      end;
   end Nearest_Option;

   function Informational_Problem (Asked : String) return String is
     (Asked & " prints and compiles nothing, so it takes no compilation"
      & " option");

   function Usage
     (Command : Action := Overview; External_Lines : String := "")
      return String
   is
      Text : US.Unbounded_String;
      Operands : constant String :=
        (case Command is
            when Check | Compile => " [options] source.ldn ...",
            when Run => " [options] source.ldn ... [-- ARGUMENT ...]",
            when Format => " [options] source.ldn|DIR ...",
            when Explain => " [options] [CODE|[NNNN]|DNNN ...]",
            when Completion => " [options] bash|zsh|fish",
            when Help => " [COMMAND|reference]",
            when others => " [options]");
   begin
      if Command = Overview then
         US.Append (Text, "usage: refine COMMAND [options] [operands]" & LF
           & LF & "Commands:" & LF);
         for Item in Action range Check .. Help loop
            US.Append (Text, "  " & Name (Item)
              & Ada.Strings.Fixed."*" (12 - Name (Item)'Length, ' ')
              & Description (Item) & LF);
         end loop;
         if External_Lines /= "" then
            US.Append (Text, LF & "External commands:" & LF
              & External_Lines);
         end if;
      else
         US.Append (Text, "usage: refine " & Name (Command) & Operands & LF
           & LF & Description (Command) & LF);
      end if;
      US.Append (Text, LF & "Options:" & LF);
      for Flag in Option loop
         if Accepts (Command, Flag) then
            declare
               Spelling : constant String :=
                 (case Flag is
                     when Help_Flag => "-h, --help",
                     when Verbose => "-v, --verbose",
                     when Quiet => "-q, --quiet",
                     when Output => "-o, --output",
                     when others => Name (Flag))
                 & (if Flag = Library_Directory
                    then " DIR"
                    elsif Takes_Value (Flag) then " VALUE" else "");
            begin
               US.Append (Text, "  " & Spelling
                 & Ada.Strings.Fixed."*" (26 - Spelling'Length, ' ')
                 & Description (Flag) & LF);
            end;
         end if;
      end loop;
      US.Append (Text, LF
        & "Shared options work before or after the command. Values may use"
        & LF & "a space or '='. "
        & (if Command = Run
           then "'--' begins the program's arguments; @FILE"
           else "Use '--' before literal operands; @FILE")
        & " reads"
        & LF & "a response file. Single-valued options may be given once."
        & LF & "Of the shared options, lsp takes only --help."
        & LF);
      case Command is
         when Overview =>
            US.Append (Text, LF & "Use 'refine COMMAND --help' or "
              & "'refine help COMMAND'." & LF
              & "--version is an alias for 'refine version'." & LF
              & "A source follows its command:"
              & LF & "  refine check SOURCE.ldn"
              & LF & "--identify is a compatibility spelling; use 'version'"
              & LF & "and 'targets'."
              & LF & "'build' runs a contributed refine-build; refine has"
              & LF & "no build command of its own."
              & LF);
         when Check | Compile | Run =>
            US.Append (Text, LF
              & "Sources form one whole program. With --root, the operand"
              & LF & "is one entry-module directory, or the entry module's"
              & LF & "source files, and its imports are found under the roots."
              & LF & "Build mode, optimization, specialization and debug"
              & LF & "information are independent. --build-mode changes"
              & LF & "generated code only where source reads"
              & LF & "compiler.build_mode."
              & LF & "--optimize chooses selection, inlining and register"
              & LF & "allocation for size or speed. --specialize turns"
              & LF & "a generic instance's evidence call into a direct one"
              & LF & "where it proves the table; all skips auto's cost test,"
              & LF & "and an instance whose address is taken, or a call"
              & LF & "through any, stays indirect. --build-report lists each"
              & LF & "call left indirect, under left_indirect, and why."
              & LF & "The build report's fields are listed under ""The build"
              & LF & "report"" in compiler/ada/README.md."
              & LF & "Example: refine " & Name (Command)
              & " program.ldn"
              & (if Command = Compile then " -o program" else "") & LF);
            if Command = Run then
               US.Append (Text, "Example: refine run program.ldn -- input.txt"
                 & LF
                 & "The executable is written into a new directory only you"
                 & LF & "may enter, under TMPDIR or /tmp, and removed when the"
                 & LF & "program ends. Arguments after -- are the program's,"
                 & LF & "exactly; write a source beginning with - as"
                 & LF & "./-name.ldn. The program runs in this directory with"
                 & LF & "this terminal, and refine exits with its status, or"
                 & LF & "with 128 and the number of the signal that ended it."
                 & LF & "Ctrl-C reaches the program through the terminal's"
                 & LF & "foreground process group. A supervisor that signals"
                 & LF & "refine alone should send SIGTERM or SIGHUP, which"
                 & LF & "refine forwards before it cleans up; SIGINT and"
                 & LF & "SIGQUIT sent to refine alone are ignored."
                 & LF & "run runs this compiler's own host; build another"
                 & LF & "target with refine compile --target=NAME." & LF);
            end if;
            if Command = Compile then
               US.Append (Text, "Example: refine compile --emit asm "
                 & "program.ldn -o program.s" & LF
                 & "Example: refine compile program.s -o program" & LF
                 & "An executable's assembly is the link's input and is"
                 & LF & "removed after it; --keep-asm keeps it as OUT.s, and"
                 & LF & "a .s operand is linked as a compiled program is,"
                 & LF & "with the same --target, --level and --link."
                 & LF & "--emit ir writes the IR the backend receives."
                 & LF & "--emit ir-annotated also records the target and"
                 & LF & "settings, module-qualified routine names and the IR's"
                 & LF & "metadata."
                 & LF
                 & "Hosted targets support --debug full; firmware targets"
                 & LF & "support --debug lines. Firmware executables require"
                 & LF & "--firmware-entry."
                 & LF
                 & "Example: refine compile --link=libc -L vendor/lib"
                 & " program.ldn -o program" & LF
                 & "linker.library(""NAME"") links libNAME, a shared"
                 & LF & "library or an archive, as the C driver's -lNAME"
                 & LF & "does; on Linux it needs --link=libc."
                 & LF & "linker.directory(""DIR"") in the source, relative to"
                 & LF & "its file, and -L DIR, relative to here, say where"
                 & LF & "libraries are, -L's first; each is"
                 & LF & "also where the program looks for them when it runs."
                 & LF);
            end if;
         when Format =>
            US.Append (Text, LF
              & "fmt reads named files or directories, not standard input."
              & LF & "refine fmt --stdout source.ldn prints one source in the"
              & LF & "layout, and an editor can format through refine lsp."
              & LF);
         when Completion =>
            US.Append (Text, LF
              & "To enable completion in the current shell:" & LF
              & "  bash: source <(refine completion bash)" & LF
              & "  zsh:  autoload -Uz compinit; compinit" & LF
              & "        source <(refine completion zsh)" & LF
              & "  fish: refine completion fish | source" & LF);
         when others => null;
      end case;
      return US.To_String (Text);
   end Usage;

   function Reference return String is
      Text : US.Unbounded_String := US.To_Unbounded_String (Usage);
   begin
      for Command in Action range Check .. Help loop
         US.Append (Text, LF & Usage (Command));
      end loop;
      return US.To_String (Text);
   end Reference;

   function Shell_Completion (Shell : String) return String is
      Commands, Text : US.Unbounded_String;
      function Options (Command : Action) return String;
      function Options (Command : Action) return String is
         Words : US.Unbounded_String;
      begin
         for Flag in Option loop
            if Accepts (Command, Flag) then
               US.Append (Words, Name (Flag) & " ");
               case Flag is
                  when Help_Flag => US.Append (Words, "-h ");
                  when Verbose => US.Append (Words, "-v ");
                  when Quiet => US.Append (Words, "-q ");
                  when Output => US.Append (Words, "--output ");
                  when others => null;
               end case;
            end if;
         end loop;
         return US.To_String (Words);
      end Options;
      --  D1485: the words no external command can be: every built-in
      --  command, as Separator joins them.  `build` is not among them
      --  (D1603): a contributed refine-build completes its own words.
      function Builtins (Separator : String) return String;
      function Builtins (Separator : String) return String is
         Words : US.Unbounded_String;
      begin
         for Command in Action range Check .. Help loop
            if Command /= Check then
               US.Append (Words, Separator);
            end if;
            US.Append (Words, Name (Command));
         end loop;
         return US.To_String (Words);
      end Builtins;
      Shape : constant String := "^[A-Za-z][A-Za-z0-9_-]*$";
   begin
      for Command in Action range Check .. Help loop
         US.Append (Commands, Name (Command) & " ");
      end loop;
      if Shell in "bash" | "zsh" then
         US.Append (Text,
           (if Shell = "zsh" then "#compdef refine" & LF else "")
           & "# Generated by refine completion " & Shell & LF
           & "_refine_complete() {" & LF
           & "  local command='' word choices" & LF);
         --  D1485: the words after an external command are its own to
         --  complete, through the dispatcher.
         if Shell = "bash" then
            US.Append (Text,
              "  if [ ""$COMP_CWORD"" -gt 1 ] && [[ ${COMP_WORDS[1]} =~ "
              & Shape & " ]]; then" & LF
              & "    case ""${COMP_WORDS[1]}"" in" & LF
              & "      " & Builtins ("|") & ") ;;" & LF
              & "      *) COMPREPLY=( $(refine ""${COMP_WORDS[1]}"""
              & " --complete -- ""${COMP_WORDS[@]:2:COMP_CWORD-1}"""
              & " 2>/dev/null) ); return ;;" & LF
              & "    esac" & LF & "  fi" & LF);
         else
            US.Append (Text,
              "  if (( CURRENT > 2 )) && [[ ${words[2]} =~ "
              & Shape & " ]]; then" & LF
              & "    case ""${words[2]}"" in" & LF
              & "      " & Builtins ("|") & ") ;;" & LF
              & "      *) compadd -- ${(f)""$(refine ""${words[2]}"""
              & " --complete -- ""${words[@]:2:$((CURRENT-2))}"""
              & " 2>/dev/null)""}; return ;;" & LF
              & "    esac" & LF & "  fi" & LF);
         end if;
         if Shell = "bash" then
            US.Append (Text,
              "  for word in ""${COMP_WORDS[@]:1:COMP_CWORD-1}""; do" & LF);
         else
            US.Append (Text,
              "  for word in ""${words[@]:1:$((CURRENT-2))}""; do" & LF);
         end if;
         US.Append (Text, "    case ""$word"" in" & LF);
         for Command in Action range Check .. Help loop
            US.Append (Text, "      " & Name (Command)
              & ") command=$word; break ;;" & LF);
         end loop;
         US.Append (Text, "    esac" & LF & "  done" & LF
           & "  case ""$command"" in" & LF);
         for Command in Action range Check .. Help loop
            US.Append (Text, "    " & Name (Command) & ") choices='"
              & Options (Command) & "' ;;" & LF);
         end loop;
         US.Append (Text, "    *) choices='" & US.To_String (Commands)
           & Options (Overview) & "' ;;" & LF & "  esac" & LF);
         if Shell = "bash" then
            US.Append (Text, "  COMPREPLY=( $(compgen -W ""$choices"""
              & " -- ""${COMP_WORDS[COMP_CWORD]}"") )" & LF & "}" & LF
              & "complete -o default -F _refine_complete refine" & LF);
         else
            US.Append (Text, "  compadd -- ${(z)choices}" & LF & "}" & LF
              & "compdef _refine_complete refine" & LF);
         end if;
      else
         --  D1485: an external command completes its own words.
         US.Append (Text, "# Generated by refine completion fish" & LF
           & "function __fish_refine_external" & LF
           & "  set -l words (commandline -opc)" & LF
           & "  test (count $words) -ge 2" & LF
           & "  and string match -qr '" & Shape & "' -- $words[2]" & LF
           & "  and not contains -- $words[2] " & Builtins (" ") & LF
           & "end" & LF
           & "function __fish_refine_external_complete" & LF
           & "  set -l words (commandline -opc)" & LF
           & "  refine $words[2] --complete -- $words[3..-1]"
           & " (commandline -ct) 2>/dev/null" & LF
           & "end" & LF
           & "complete -c refine -n __fish_refine_external -f -a"
           & " '(__fish_refine_external_complete)'" & LF);
         for Command in Action range Check .. Help loop
            US.Append (Text, "complete -c refine -n "
              & "'__fish_use_subcommand' -a " & Name (Command) & LF);
         end loop;
         for Flag in Option loop
            declare
               Conditions : US.Unbounded_String;
               Stem : constant String := Name (Flag);
            begin
               for Command in Action loop
                  if Accepts (Command, Flag) then
                     if US.Length (Conditions) > 0 then
                        US.Append (Conditions, "; or ");
                     end if;
                     US.Append (Conditions,
                       (if Command = Overview then "__fish_use_subcommand"
                        else "__fish_seen_subcommand_from " & Name (Command)));
                  end if;
               end loop;
               US.Append (Text, "complete -c refine -n '"
                 & US.To_String (Conditions) & "' "
                 & (if Stem = "-o" then "-s o -l output"
                    elsif Stem = "-L" then "-s L"
                    else "-l " & Stem (3 .. Stem'Last))
                 & (if Takes_Value (Flag) then " -r" else "") & LF);
            end;
         end loop;
      end if;
      return US.To_String (Text);
   end Shell_Completion;

end Landin.Commands.Catalogue;
