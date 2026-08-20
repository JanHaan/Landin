--  The `refine` request/result boundary.
--
--  A request is parsed from arguments; a result carries an exit status, the
--  text a caller asked for and the rendered report.  Nothing here decides
--  anything about the Landin language: the compiler has no frontend yet and
--  says so as a diagnostic rather than by crashing or by pretending.

with Ada.Strings.Unbounded;

with Landin.Platform;

package Landin.Driver is

   --  Exit statuses are part of the interface a test asserts, so they are
   --  named rather than spelled at each return.
   Status_Success   : constant := 0;
   Status_Reported  : constant := 1;
   Status_Misuse    : constant := 2;

   type Outcome is record
      Status : Natural := Status_Success;
      Output : Ada.Strings.Unbounded.Unbounded_String;
      Report : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Host is the only way this reaches a disk, which is why the whole
   --  driver is testable with a fake filesystem.
   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class) return Outcome;

   --  Identity without a version.  This roadmap assigns no release
   --  designation, so neither does the executable.
   function Identity return String;

   function Usage return String;

end Landin.Driver;
