--  Where the repository-owned library is.
--
--  `core`, `hosted` and `platform` are not packages.  The compiler names
--  them, decides their availability by target (D267) and holds its hosted
--  contracts to them, so a compiler and a library from different revisions
--  are a fault, and the library is found beside the compiler that was built
--  with it rather than wherever a request happens to point.  Two layouts
--  hold one: an installation puts it in PREFIX/lib/landin beside
--  PREFIX/bin/refine, and a checkout's build leaves `refine` in
--  REPO/compiler/ada/build/TAG/MODE/bin with the library at REPO.  An
--  explicit `--library=DIR` replaces both for an unusual installation.
--
--  Where the executable is is the host's answer, through
--  `Landin.Platform`; a parent is taken by cutting a name off that answer
--  rather than by writing `..` into a path a diagnostic may later show.

with Landin.Platform;

package Landin.Driver.Library is

   --  Whether an import's logical path names the library: its first
   --  segment is `core`, `hosted` or `platform`.  Such an import resolves
   --  from the library root alone whenever there is one.
   function Is_Library_Import (Logical : String) return Boolean;

   --  Whether Directory holds a library: it has a `core`, `hosted` or
   --  `platform` directory.  A build that stages only the modules it
   --  reaches, as the firmware lanes do, still names a library.
   function Holds_Library
     (Host : Landin.Platform.Filesystem'Class; Directory : String)
      return Boolean;

   --  The library beside this compiler's executable, installed layout
   --  first and then a checkout's, or "" when the host cannot say where
   --  the executable is or neither layout holds one.
   function Located (Host : Landin.Platform.Filesystem'Class) return String;

   --  Where Located looked, as a refusal names it (D363): the prefix's
   --  `lib/landin` beside the executable and the checkout a build tree's
   --  executable sits in, or that the executable's directory is unknown.
   function Looked_In (Host : Landin.Platform.Filesystem'Class)
     return String;

end Landin.Driver.Library;
