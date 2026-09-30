--  How a request's sources reach a compilation.
--
--  Two ways, as the command line has two: named files, each read once and
--  resolved together as one module [1480], or one entry directory whose
--  imports are found under ordered roots [1410]-[1420].  The loader is the
--  driver's and a server's alike, so a buffer an editor holds open is read
--  exactly as `refine` would read the file it will be saved as; which bytes
--  a path holds is the host's answer, never the loader's.
--
--  A rooted load scans and parses each module as it reaches it, because its
--  imports are what name the next, and stops at the first that does not
--  scan or parse.  Whatever it could not read or find is reported into the
--  compilation, as every other refusal is.

with Landin.Platform;
with Landin.Stages;

package Landin.Driver.Loading is

   --  Each path in order, the first spelling of a file kept and a second
   --  name for it dropped.  A path that cannot be read is L0003.
   procedure Load_Files
     (Context : in out Landin.Stages.Compilation;
      Host    : Landin.Platform.Filesystem'Class;
      Paths   : Landin.Platform.Path_List);

   --  The entry module and every module its imports reach, first in first
   --  out, each loaded once.  Roots are searched in order and must be
   --  nonempty.
   procedure Load_Reachable_Program
     (Context         : in out Landin.Stages.Compilation;
      Host            : Landin.Platform.Filesystem'Class;
      Roots           : Landin.Platform.Path_List;
      Entry_Directory : String);

   function Joined_Path (Directory, Child : String) return String;

   function Is_Source_Name (Name : String) return Boolean;

end Landin.Driver.Loading;
