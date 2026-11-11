--  One catalogue supplies parsing, help, completion and the CLI reference.
with Ada.Strings.Unbounded;

package Landin.Commands.Catalogue is

   type Action is
     (Overview, Check, Compile, Run, Format, Svd, Bindings, Explain, Site,
      Server,
      Version, Targets, Completion, Help);

   function Name (Command : Action) return String;
   function Description (Command : Action) return String;
   function Known (Text : String) return Boolean;
   function Named (Text : String) return Action with Pre => Known (Text);

   type Option is
     (Help_Flag, Verbose, Quiet, Color, Diagnostics,
      Target, Level, Root, Library, Library_Directory, Build_Option,
      Build_Mode, Optimize, Specialize, Emit, Output, Keep_Asm, Debug,
      Panic_Map, Toolchain, Linker, Link,
      Firmware_Entry, Firmware_Layout, Linker_Script, Build_Report,
      Stage_Report,
      Stack_Report, Dry_Run,
      Depfile,
      Format_Check, Format_Stdout, Explain_Full, Stdio, JSON, Warnings, Warn,
      Allow, Deny, Policy, Out_Dir, Clang, Sysroot, Include_Dir,
      System_Include_Dir, Define, Map, Dsym);

   function Name (Flag : Option) return String;
   function Description (Flag : Option) return String;
   function Values (Flag : Option) return String;
   function Takes_Value (Flag : Option) return Boolean;
   function Shared (Flag : Option) return Boolean;
   function Accepts (Command : Action; Flag : Option) return Boolean;
   --  The commands that take a command-specific option, as a reader says
   --  them: "check, compile and version"; and the first of them.
   function Owners (Flag : Option) return String;
   function First_Owner (Flag : Option) return Action;
   function Repeatable (Flag : Option) return Boolean;
   function Valid_Value (Flag : Option; Text : String) return Boolean;
   function Known_Option (Text : String) return Boolean;
   function Named_Option (Text : String) return Option
     with Pre => Known_Option (Text);

   --  D565: what an option needs of the rest of its request, one column
   --  read by the commands' parse and by the driver alike, so a request
   --  is refused for one rule with one sentence whichever reads it first.
   type Requirement is
     (Nothing,
      --  A source to compile.
      A_Source,
      --  Emitted machine code, --emit=asm or --emit=exe.
      Machine_Code,
      --  An executable, --emit=exe.
      An_Executable,
      --  Something emitted at all.
      An_Artifact);

   function Needs (Flag : Option) return Requirement;

   --  D589: Emit_Linker_Script writes the selected profile's derived
   --  linker script, and with --build-report its limits, without a link.
   type Emission is
     (No_Emission, Emit_Asm, Emit_Exe, Emit_IR, Emit_Linker_Script);

   --  Why FLAG cannot be in a request that emits EMITTED and names a
   --  source or not, or "" when it can.
   function Requirement_Problem
     (Flag : Option; Emitted : Emission; Has_Source : Boolean)
      return String;

   --  Whether FLAG is one the driver reads for a compilation: what
   --  check, compile and run hand on after the commands' own options.
   function Compilation_Option (Flag : Option) return Boolean;

   --  The sentences both readers refuse a written option with: a single
   --  one given twice, a value it does not take, and a compilation option
   --  beside a request that prints and compiles nothing.
   function Given_Twice (Stem : String) return String;
   function Value_Problem (Flag : Option; Value : String) return String;

   --  The values a valued option takes, "; it takes none, full or lines",
   --  or "" for one whose value is a name or a path, so a refusal of a
   --  missing value says what to write.
   function Value_Choices (Flag : Option) return String;

   --  What to offer for an option nobody defined, or "": the option meant
   --  by another compiler's spelling, `--debug=full` for `-g`, and
   --  otherwise the nearest compilation option.  Both readers ask it.
   function Nearest_Option (Stem : String) return String;
   function Informational_Problem (Asked : String) return String;

   function Usage (Command : Action := Overview) return String;
   function Reference return String;
   function Shell_Completion (Shell : String) return String;

private
   package US renames Ada.Strings.Unbounded;
end Landin.Commands.Catalogue;
