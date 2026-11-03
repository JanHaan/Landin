--  `refine bindings`: bind C headers for Landin (D820, D821).
--
--  The command checks its request, reads the headers and the policy, and
--  runs the named Clang through Landin.Platform for everything a header
--  says: the target's triple and macros, the preprocessed headers, their
--  JSON AST, the enum probe and the compilation of the generated adapters.
--  Each Clang runs with -nostdinc, the roots and defines the request
--  names, and an environment of PATH, HOME and the temporary directory
--  alone.  Landin.Bindings makes the four outputs from what Clang printed.
--
--  Replacement is refine svd's: every destination is checked first, every
--  new file is written beside its destination and read back, and only
--  then is each destination replaced, its old bytes kept beside it until
--  all are; a failure puts back what was replaced.  A file whose bytes are
--  already the new ones is left alone.  This is recovery from a failure,
--  not a snapshot for a concurrent reader.

with Ada.Strings.Unbounded;
with Landin.Driver;
with Landin.Platform;

package Landin.Commands.Bindings is

   type Request is record
      Clang     : Ada.Strings.Unbounded.Unbounded_String;
      --  A refine target name, or "" for the host's.
      Target    : Ada.Strings.Unbounded.Unbounded_String;
      Sysroot   : Ada.Strings.Unbounded.Unbounded_String;
      Policy    : Ada.Strings.Unbounded.Unbounded_String;
      Out_Dir   : Ada.Strings.Unbounded.Unbounded_String;
      --  Each `[LOGICAL=]PATH`.
      Headers   : Landin.Platform.Path_List;
      Include_Dirs : Landin.Platform.Path_List;
      System_Include_Dirs : Landin.Platform.Path_List;
      Defines   : Landin.Platform.Path_List;
   end record;

   procedure Generate
     (Asked     : Request;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String;
      Result    : in out Landin.Driver.Outcome);

end Landin.Commands.Bindings;
