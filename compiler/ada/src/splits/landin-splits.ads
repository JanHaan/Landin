--  What every split command shares: its process surface (D1485, D1544).
--
--  A split command is its own executable, `refine-NAME`, which `refine
--  NAME` runs (D1383, D1384).  Its process is its whole contract with
--  `refine`: it reads its own arguments and response files, answers
--  `--describe` (D1387), `--help` and `--complete -- WORD...`, and takes the
--  shared presentation options a built-in command takes, so a request
--  written for the command before it was split means what it meant.
--
--  This unit and its children must never with Landin.Driver or
--  Landin.Commands, whose bodies with the whole compiler: a split links
--  what it uses and nothing of the front end, and a closure pin for each
--  main in scripts/tests/test_unit_closure.py holds it so (D1543).

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Landin.Diagnostics.Catalogue;
with Landin.Outcomes;
with Landin.Platform;
with Landin.Presentation;

package Landin.Splits is

   package US renames Ada.Strings.Unbounded;

   --  An option of the command's own.  Name is its spelling, `--policy`;
   --  Value_Name what its help writes after it, "" for a flag; Repeatable
   --  whether it may be given more than once.
   type Option is record
      Name        : US.Unbounded_String;
      Value_Name  : US.Unbounded_String;
      Description : US.Unbounded_String;
      Repeatable  : Boolean := False;
   end record;

   function Flag (Name, Description : String) return Option;
   function Valued
     (Name, Value_Name, Description : String;
      Repeatable : Boolean := False) return Option;

   type Option_Array is array (Positive range <>) of Option;

   --  What the command says of itself.  Usage is what follows `refine
   --  NAME` in its usage line; Notes the help's closing paragraphs.
   type Command is record
      Name    : US.Unbounded_String;
      Summary : US.Unbounded_String;
      Usage   : US.Unbounded_String;
      Notes   : US.Unbounded_String;
   end record;

   type Mode is (Run, Help, Describe, Complete);

   package Value_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Landin.Platform.Path_List,
      "=" => Landin.Platform.Path_Vectors."=");

   --  A parsed request.  Values holds, for the command's option at each
   --  index of its Option_Array, every value given, in order.
   type Request is record
      Wanted    : Mode := Run;
      Values    : Value_Vectors.Vector;
      Operands  : Landin.Platform.Path_List;
      --  The words `--complete --` was given, the last the one completed.
      Completed : Landin.Platform.Path_List;
      Verbosity : Natural := 0;
      Quiet     : Boolean := False;
      Color     : US.Unbounded_String := US.To_Unbounded_String ("auto");
      Style     : Landin.Presentation.Style := Landin.Presentation.Human;
      Consumed_Response_Files : Landin.Platform.Path_List;
      Consumed_Response_Identities : Landin.Platform.Identity_List;
      Problem   : US.Unbounded_String;
   end record;

   --  Whether the option at Index was given, its last value or "", and
   --  every value given for it, a flag's as one "" each time it was.
   function Given (Asked : Request; Index : Positive) return Boolean;
   function Value (Asked : Request; Index : Positive) return String;
   function Values
     (Asked : Request; Index : Positive) return Landin.Platform.Path_List;

   --  What a command does with a request that asks it to run.  The request
   --  has parsed; its operands and values are the command's to judge.
   type Runner is access function
     (Asked     : Request;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String) return Landin.Outcomes.Outcome;

   --  The whole of a split's run: parse Arguments, answer `--describe`,
   --  `--help` and `--complete` itself, refuse a request that does not
   --  parse with L0002 at status 2, and otherwise call Perform and present its
   --  report as `--diagnostics` and `--color` ask.
   function Execute
     (About     : Command;
      Options   : Option_Array;
      Perform   : Runner;
      Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String;
      Terminal_Color : Boolean := False) return Landin.Outcomes.Outcome;

   --  A refusal with no source, of the code named Code, at Status: what a
   --  runner says of a request it cannot carry out.
   function Refused
     (Code    : Landin.Diagnostics.Catalogue.Code_Name;
      Message : String;
      Status  : Natural) return Landin.Outcomes.Outcome;

   --  The parts Execute answers with, for the commands suite to hold.
   function Parse
     (Options   : Option_Array;
      Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class) return Request;
   function Usage (About : Command; Options : Option_Array) return String;
   function Description (About : Command) return String;
   function Completion
     (Options : Option_Array; Words : Landin.Platform.Path_List)
      return String;

end Landin.Splits;
