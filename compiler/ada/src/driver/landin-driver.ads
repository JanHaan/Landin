--  The `refine` request/result boundary.
--
--  A request is parsed from arguments; a result carries an exit status, the
--  text a caller asked for and the rendered report.  Nothing here decides
--  anything about the Landin language: what a program means is the four
--  frontend stages', and what an instruction is is the backend's.
--
--  Two host capabilities, for the same reason there was one.  R0.50's rule
--  is that every host effect reaches the compiler through a
--  `Landin.Platform` interface so a whole compilation can be driven against
--  fakes, and R1.80 is the first work that needs the second of them: a
--  request may now write a file and run a tool.  Both are parameters rather
--  than package state, so a test names exactly the host it wants.

with Ada.Strings.Unbounded;

with Landin.Platform;

package Landin.Driver is

   --  Exit statuses are part of the interface a test asserts, so they are
   --  named rather than spelled at each return.
   Status_Success   : constant := 0;
   Status_Reported  : constant := 1;
   Status_Misuse    : constant := 2;

   --  The compiler finding itself wrong, which is not the program being
   --  wrong and must not be read as it.  Sysexits' EX_SOFTWARE, which is
   --  what `refine` already exited with, moved here so that a defect is
   --  an outcome this boundary returns rather than an exception that
   --  escapes it -- and so that whatever the run had already decided is
   --  still rendered beside it.
   Status_Defect    : constant := 70;

   type Outcome is record
      Status : Natural := Status_Success;
      Output : Ada.Strings.Unbounded.Unbounded_String;
      Report : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Host and Tools are the only ways this reaches a disk or a process,
   --  which is why the whole driver is testable without either.
   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class) return Outcome;

   --  Identity without a version.  This roadmap assigns no release
   --  designation, so neither does the executable.
   function Identity return String;

   function Usage return String;

   --  What `--emit=exe` writes beside its output, and reads back as the
   --  assembler's input.  Named here because a test asserts the path and a
   --  reader should not have to infer it from a concatenation.
   function Assembly_Beside (Output : String) return String
     is (Output & ".s");

   --  What `-o` defaults to when a request does not say.  Deliberately not
   --  derived from an input file name: a compilation is one module made of
   --  any number of files [1480], so there is no one input to name it
   --  after.
   Default_Executable : constant String := "a.out";
   Default_Assembly   : constant String := "a.s";

end Landin.Driver;
