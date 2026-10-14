--  How a request's sources reach a compilation.
--
--  Two ways, as the command line has two: named files, each read once and
--  resolved together as one module [1480], or one entry directory whose
--  imports are found under ordered roots [1410]-[1420].  The loader is the
--  driver's and a server's alike, so a buffer an editor holds open is read
--  exactly as `refine` would read the file it will be saved as; which bytes
--  a path holds is the host's answer, never the loader's.  Either way, an
--  import of `core`, `hosted` or `platform` is found under the library
--  root when there is one.
--
--  A rooted load scans and parses each module as it reaches it, because its
--  imports are what name the next, and stops at the first that does not
--  scan or parse.  Whatever it could not read or find is reported into the
--  compilation, as every other refusal is.

with Landin.Platform;
with Landin.Stages;
with Landin.Stages.Syntax;

package Landin.Driver.Loading is

   --  Each path in order, the first spelling of a file kept and a second
   --  name for it dropped.  A path that cannot be read is L0003.
   procedure Load_Files
     (Context : in out Landin.Stages.Compilation;
      Host    : Landin.Platform.Filesystem'Class;
      Paths   : Landin.Platform.Path_List);

   --  The entry module and every module its imports reach, first in first
   --  out, each loaded once.  Roots are searched in order and must be
   --  nonempty.  When requested, record every root-relative directory
   --  where an unresolved import could later become available.
   --
   --  Library, when not empty, is the library root
   --  (`Landin.Driver.Library`), and follows every root.  An import of
   --  the library resolves from it alone and any other from Roots alone,
   --  so the rest of a checkout that holds the library is never a root
   --  nobody named.  A root that names the library's own directory is
   --  searched once, under the spelling the request gave it.
   procedure Load_Reachable_Program
     (Context         : in out Landin.Stages.Compilation;
      Host            : Landin.Platform.Filesystem'Class;
      Roots           : Landin.Platform.Path_List;
      Entry_Directory : String;
      Missing_Directories : access Landin.Platform.Path_List := null;
      Previous        : access Landin.Stages.Compilation := null;
      Watch_Syntax    : access procedure (Name : String) := null;
      Cache           : access Landin.Stages.Syntax.Parse_Cache := null;
      Dependency_Directories : access Landin.Platform.Path_List := null;
      Library         : String := "";
      Implicit        : String := "");

   --  After Load_Files, for named files with a library root: what they
   --  read is parsed, and every library module their imports reach is
   --  loaded from Library as Load_Reachable_Program loads one, and every
   --  module those reach.  The named files stay the one entry module.  An
   --  import of anything else is left unresolved for resolution to refuse
   --  (D262), and an import the target does not admit, or of the
   --  toolchain, is left for configuration to refuse, as it is with no
   --  library at all.
   procedure Load_Library_Imports
     (Context      : in out Landin.Stages.Compilation;
      Host         : Landin.Platform.Filesystem'Class;
      Library      : String;
      Previous     : access Landin.Stages.Compilation := null;
      Watch_Syntax : access procedure (Name : String) := null;
      Cache        : access Landin.Stages.Syntax.Parse_Cache := null;
      Dependency_Directories : access Landin.Platform.Path_List := null;
      Implicit     : String := "");

   --  Implicit, in either load, names one library module the program holds
   --  whether or not an import reaches it: platform/linux, whose process
   --  entry a static Linux executable starts at.  It is loaded from the
   --  library after everything the imports reach, unless one already did.

   function Joined_Path (Directory, Child : String) return String;

   function Is_Source_Name (Name : String) return Boolean;

end Landin.Driver.Loading;
