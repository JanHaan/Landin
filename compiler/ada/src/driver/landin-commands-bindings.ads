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
--  All destinations are snapshotted before Clang runs. The shared Platform
--  transaction validates the complete staged set, captures prior versions
--  and publishes without replacing a concurrently occupied name. Conflicts
--  preserve foreign files and name retained recovery; equal outputs keep
--  their original inode. Group visibility is not atomic.

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
      Protected_Inputs : Landin.Platform.Path_List;
      Protected_Identities : Landin.Platform.Identity_List;
   end record;

   procedure Generate
     (Asked     : Request;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String;
      Result    : in out Landin.Driver.Outcome);

end Landin.Commands.Bindings;
