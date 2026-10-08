--  One catalogue supplies parsing, help, completion and the CLI reference.
with Ada.Strings.Unbounded;

package Landin.Commands.Catalogue is

   type Action is
     (Overview, Check, Compile, Format, Explain, Server, Version,
      Targets, Completion, Help);

   function Name (Command : Action) return String;
   function Description (Command : Action) return String;
   function Known (Text : String) return Boolean;
   function Named (Text : String) return Action with Pre => Known (Text);

   type Option is
     (Help_Flag, Verbose, Quiet, Color, Diagnostics,
      Target, Level, Root, Build_Option, Build_Mode, Optimize, Specialize,
      Emit, Output, Debug, Panic_Map, Toolchain, Linker, Firmware_Entry,
      Build_Report, Stage_Report, Dry_Run, Depfile, Format_Check, Stdio,
      JSON, Warnings, Warn, Allow, Deny);

   function Name (Flag : Option) return String;
   function Description (Flag : Option) return String;
   function Values (Flag : Option) return String;
   function Takes_Value (Flag : Option) return Boolean;
   function Shared (Flag : Option) return Boolean;
   function Accepts (Command : Action; Flag : Option) return Boolean;
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
