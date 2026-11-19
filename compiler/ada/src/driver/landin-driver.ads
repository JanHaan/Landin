--  The `refine` request/result boundary.
--
--  A request is parsed from arguments; a result carries an exit status, the
--  text a caller asked for and the rendered report.  Nothing here decides
--  anything about the Landin language: what a program means is the four
--  frontend stages', and what an instruction is is the backend's.
--
--  Two host capabilities, for the same reason there was one.  The compiler's
--  rule is that every host effect reaches it through a `Landin.Platform`
--  interface so a whole compilation can be driven against fakes, and the
--  native path is the first work that needs the second of them: a request may
--  now write a file and run a tool.  Both are parameters rather than package
--  state, so a test names exactly the host it wants.


with Landin.Diagnostics;
with Landin.Diagnostics.Warning_Policy;
with Landin.Outcomes;
with Landin.Platform;
with Landin.Targets.Selection;

package Landin.Driver is

   --  The statuses and the outcome are Landin.Outcomes', which the split
   --  commands share without linking the driver (D1543).
   Status_Success  : constant := Landin.Outcomes.Status_Success;
   Status_Reported : constant := Landin.Outcomes.Status_Reported;
   Status_Misuse   : constant := Landin.Outcomes.Status_Misuse;
   Status_Defect   : constant := Landin.Outcomes.Status_Defect;

   package Position_Vectors renames Landin.Outcomes.Position_Vectors;

   subtype Outcome is Landin.Outcomes.Outcome;

   --  Host and Tools are the only ways this reaches a disk or a process,
   --  which is why the whole driver is testable without either.
   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class) return Outcome;

   --  The same request, with a meter for `--stage-report=PATH`.  Without
   --  one, the report is written with every measurement zero, which is what
   --  a fake host has to offer.
   --  BUILT_FOR is the triplet whose host a build that names no target is
   --  for (D257).  It is the compiler's own build, and a test names another
   --  to reach every answer through this one path.
   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Meter     : Landin.Platform.Resource_Meter'Class;
      Built_For : String := Landin.Targets.Selection.Build_Triplet;
      Dry_Run   : Boolean := False;
      Depfile   : String := "";
      Warnings  : Landin.Diagnostics.Warning_Policy.Policy :=
        Landin.Diagnostics.Warning_Policy.Defaults;
      Protected_Inputs : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments;
      Protected_Identities : Landin.Platform.Identity_List :=
        Landin.Platform.Identity_Vectors.Empty_Vector) return Outcome;

   --  Identity without a version.  This roadmap assigns no release
   --  designation, so neither does the executable.
   function Identity return String;

   function Usage return String;

   --  `refine explain [CODE ...]`: every code's rule with no operand, or
   --  each named code's explanation in the order named.  A subcommand and
   --  not an option, because it reads no source and compiles nothing: the
   --  first argument, spelled exactly, selects it, so a source must be
   --  named with a path to be called `explain`.  It reads no source and
   --  writes no file; a citation, `[NNNN]` or `DNNN`, it answers from
   --  `citations.txt` in the library, or under `--library=DIR`, read at
   --  most once and only when one is asked for (D1240).
   Explain_Command : constant String := "explain";

   --  `refine fmt [--check | --stdout] FILE|DIR ...`: every named source,
   --  and every `.ldn` file under a named directory, a dot-named one left
   --  out, in
   --  D252's one layout, written into its file when it is not in it
   --  already (D358).  With `--check` nothing is written and every line
   --  out of the layout is an L0008 that shows the line as the layout
   --  writes it (D359).  With `--stdout` the one source named is written
   --  to standard output in the layout, and its file is left as it is.  A
   --  source that does not scan or parse is refused with its own report
   --  and left as it is, and the others are formatted all the same.  Each
   --  file stands alone: no import is followed and no other stage runs, so
   --  a directory operand is a set of files to lay out and never a module
   --  directory to resolve.  The two
   --  options choose where the layout goes and never what it is.
   Format_Command : constant String := "fmt";

   --  `refine lsp [--stdio]`: a language server over standard input and
   --  output, which `refine` runs itself before it asks this package
   --  anything, because it needs the process's channel and not a request
   --  and a result.  Here is only its misuse: any argument after it but
   --  the `--stdio` an editor's client adds by convention is refused, and
   --  Is_Server says which argument lists start one.
   Server_Command : constant String := "lsp";

   function Is_Server (Arguments : Landin.Platform.Path_List)
     return Boolean;

   --  What `--emit=exe` writes beside its output, and reads back as the
   --  assembler's input.  Named here because a test asserts the path and a
   --  reader should not have to infer it from a concatenation.  On a
   --  hosted target it is removed after the link unless `--keep-asm`
   --  asks to keep it or a source map beside the executable names it
   --  (D362); firmware keeps it with its link's object, script and map.
   function Assembly_Beside (Output : String) return String
     is (Output & ".s");

   --  What `-o` defaults to when a request does not say.  Deliberately not
   --  derived from an input file name: a compilation is one module made of
   --  any number of files [1480], so there is no one input to name it
   --  after.

   --  Path of the off-target source map beside an emitted output.  Written
   --  when source debugging is enabled (`--debug=full` or `--debug=lines`),
   --  `--panic-map` is requested, or emitted code injects caller
   --  coordinates.  Never an assembler or linker input.
   function Source_Map_Beside (Output : String) return String
     is (Output & ".sources.json");

   Default_Executable : constant String := "a.out";
   Default_Assembly   : constant String := "a.s";
   Default_IR         : constant String := "a.ir";
   Default_Script     : constant String := "a.ld";

end Landin.Driver;
