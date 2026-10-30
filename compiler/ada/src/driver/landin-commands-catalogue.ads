--  One catalogue supplies parsing, help, completion and the CLI reference.
with Ada.Strings.Unbounded;

package Landin.Commands.Catalogue is

   type Action is
     (Overview, Check, Compile, Run, Format, Explain, Server, Version,
      Targets, Completion, Help);

   function Name (Command : Action) return String;
   function Description (Command : Action) return String;
   function Known (Text : String) return Boolean;
   function Named (Text : String) return Action with Pre => Known (Text);

   type Option is
     (Help_Flag, Verbose, Quiet, Color, Diagnostics,
      Target, Level, Root, Library, Library_Directory, Build_Option,
      Build_Mode, Optimize, Specialize, Emit, Output, Keep_Asm, Debug,
      Panic_Map, Toolchain, Linker, Link,
      Firmware_Entry, Build_Report, Stage_Report, Stack_Report, Dry_Run,
      Depfile,
      Format_Check, Format_Stdout, Explain_Full, Stdio, JSON, Warnings, Warn,
      Allow, Deny);

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

   function Usage (Command : Action := Overview) return String;
   function Reference return String;
   function Shell_Completion (Shell : String) return String;

private
   package US renames Ada.Strings.Unbounded;
end Landin.Commands.Catalogue;
