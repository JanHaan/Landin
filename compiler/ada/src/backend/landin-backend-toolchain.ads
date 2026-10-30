--  The one external invocation that finishes a compilation.
--
--  [1550] says Landin "emits deterministic assembly text and relies on the
--  assembler and linker of the platform", so what is spelled here is a
--  command line selected by target policy. ELF build IDs and GNU archive
--  flags belong to the Linux policy; other targets must supply their own.
--
--  A driver is named, not a linker.  The three things a hosted program
--  needs beyond its own instructions -- the C runtime's startup objects,
--  `-lc`, and the dynamic loader's path -- live in the compiler driver and
--  not in `ld`, and they differ per distribution.  Asking a compiler driver
--  to finish the job keeps that knowledge out of this compiler; invoking a
--  linker directly would move every one of those paths in here, where no
--  paragraph of the specification could say what they are.
--
--  The Linux and Cortex-M drivers follow the GNU triplet-prefix convention:
--  `Landin.Targets.Capabilities.Triplet` supplies the prefix and `-gcc`
--  completes the name.  The pinned Linux image has
--  `x86_64-pc-linux-gnu-gcc`; Cortex-M uses `arm-none-eabi-gcc`.  Darwin
--  instead defaults to Apple's `/usr/bin/clang`, with `-arch arm64` in its
--  link arguments.  A named driver overrides any of these defaults.
--
--  A Linux target names the drivers a stock distribution installs as
--  well (D364): the pinned image's `x86_64-pc-linux-gnu-gcc` first, then
--  Debian's and Ubuntu's `x86_64-linux-gnu-gcc`, Fedora's
--  `x86_64-redhat-linux-gcc` and the `unknown` vendor's spelling, each a
--  GCC that assembles and links for that machine and no other.  A bare
--  `gcc` is the last candidate only when the target is the compiler's own
--  host, where the host's GCC is a driver for it; for any other target it
--  would hand the assembly to the host's assembler, which is why it is
--  never tried there.  It is `gcc` and not `cc` because the link line
--  passes the GNU assembler's own options.  The driver takes the first
--  candidate the host can start.
--
--  Whether the named driver exists is not asked here either.  A tool that
--  cannot be started raises `External_Tool_Failed` from
--  `Landin.Platform.Tool_Runner`, which is already the interface's stated
--  line between a tool that could not be run and one that ran and failed,
--  so no PATH is searched twice.

with Landin.Platform;
with Landin.Targets;
with Landin.Targets.Levels;

package Landin.Backend.Toolchain is

   --  The program that turns assembly text into an executable.  `Named`
   --  overrides the target's default driver; an empty `Named` selects the
   --  triplet-prefixed GCC for Linux and Cortex-M, or `/usr/bin/clang` for
   --  Darwin.  An empty result means the target names no toolchain and none
   --  was given, which is the one case that cannot be attempted rather than
   --  merely failing.
   --  Darwin retains the full source/assembly digest without filenames.
   --  Linux ELF passes the same digest through a GNU linker build ID.
   --  Cortex-M0 ELF stores it in a nonallocated .landin_id section for
   --  debugger matching and disables GNU linker build IDs.
   function Identity_Section
     (Build_Id : String; Facts : Landin.Targets.Target_Facts) return String;

   --  Auxiliary native-debug outputs and bundle containment, so the driver
   --  can protect source inputs without knowing a platform's packaging.
   function Debug_Artifacts
     (Output : String; Facts : Landin.Targets.Target_Facts;
      Host : Landin.Platform.Filesystem'Class)
      return Landin.Platform.Path_List;
   function Debug_Overwrites
     (Output, Source : String; Facts : Landin.Targets.Target_Facts;
      Host : Landin.Platform.Filesystem'Class) return Boolean;

   function Driver_For
     (Facts : Landin.Targets.Target_Facts;
      Named : String) return String;

   --  Every driver a link may use, in the order tried: Named alone when
   --  it is given, Driver_For's otherwise and, on Linux, the other
   --  distributions' spellings of the same GCC, then `gcc` when Native
   --  says the target is the compiler's own host.  Empty exactly when
   --  Driver_For is.
   function Driver_Candidates
     (Facts : Landin.Targets.Target_Facts;
      Named : String;
      Native : Boolean) return Landin.Platform.Path_List;

   --  What to install when no candidate can be started, as a note names
   --  it: the package a stock distribution gives the driver in, or the
   --  tools an operating system's vendor ships.
   function Install_Advice
     (Facts : Landin.Targets.Target_Facts;
      Named : String;
      Native : Boolean) return String;

   --  D525: the files a failed link's `-lNAME` may have meant, in the
   --  order the target's linker prefers them in one directory: on Darwin
   --  `libNAME.tbd`, `libNAME.dylib` and `libNAME.a`, elsewhere
   --  `libNAME.so` and `libNAME.a`.  Searched only after a link failed.
   function Library_Files
     (Facts : Landin.Targets.Target_Facts; Name : String)
      return Landin.Platform.Path_List;

   --  What asks the driver where its own directories hold File.  The
   --  driver answers with a path when it found one and with File alone
   --  when it did not; it does not search the `-L` directories.
   function Print_File_Arguments (File : String)
     return Landin.Platform.Path_List
     is (Landin.Platform.Arguments ("-print-file-name=" & File));

   --  The whole command line, in the order a reader would write it.
   --  Relative file operands beginning with '-' or '@' gain './' so the
   --  driver reads the named file rather than an option or response file.
   --
   --  `Static` (Linux only) links the program alone: no C runtime
   --  object or library, no dynamic loader and no position independence,
   --  starting at platform/linux's `_landin_start`.
   --
   --  `Libraries` are D523's: each `linker.library` NAME reaches the
   --  driver as `-lNAME`, in source order with its repeats, after the
   --  program's assembly, and the driver resolves it as it would for C.
   --  `Directories` are D524's absolute directories, the command line's
   --  first and then the directives', each passed before the assembly as
   --  `-LDIR` and, in the same order, as the executable's runtime search
   --  path.  Neither is admitted by a static or a firmware link.
   --
   --  `Threads` (FreeBSD only) links libthr, which holds FreeBSD's
   --  `pthread_create`: its libc has only stubs of the rest (D518).
   --
   --  `Linker` is a pass-through and not a second driver.  mold, the linker
   --  this exists for, documents three ways to be used and every one of
   --  them goes *through* a compiler driver, for the reason the header
   --  gives: `-fuse-ld=NAME` on GCC 12.1 and later, `-B<dir>` on older, or
   --  `mold -run`.  So selecting a linker changes one argument and not the
   --  shape of the invocation.  The empty string leaves the driver's own
   --  default alone.
   --
   --  A CPU feature level is passed to the tools, so that the assembler
   --  refuses an instruction the level does not have and the linker selects
   --  the runtime and records the level that the build assumed (D255).  On
   --  x86-64 the assembler is held to the level at the baseline too; on the
   --  M profile the baseline keeps naming its core, as it always did.
   function Assemble_Arguments
     (Assembly, Output : String; Facts : Landin.Targets.Target_Facts;
      Debug : Boolean := False;
      Level : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Landin.Targets.Cortex_M))
      return Landin.Platform.Path_List
     with Pre => Landin.Targets.Levels.Belongs_To (Level, Facts);

   function Link_Arguments
     (Assembly : String;
      Output   : String;
      Linker   : String;
      Build_Id : String := "";
      Libraries : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments;
      Facts : Landin.Targets.Target_Facts;
      Full_Debug : Boolean := False;
      Level : Landin.Targets.Levels.Feature_Level;
      Static : Boolean := False;
      Threads : Boolean := False;
      Directories : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments)
      return Landin.Platform.Path_List
     with Pre => Landin.Targets.Levels.Belongs_To (Level, Facts);

   --  The same at the target's default level.
   function Link_Arguments
     (Assembly : String;
      Output   : String;
      Linker   : String;
      Build_Id : String := "";
      Libraries : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments;
      Facts : Landin.Targets.Target_Facts;
      Full_Debug : Boolean := False;
      Static : Boolean := False;
      Directories : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments)
      return Landin.Platform.Path_List;

   --  The GNU assembler's `-march=` for an x86-64 level: `generic64`, the
   --  psABI baseline, with each extension the level adds.  The pinned
   --  assembler does not accept the psABI's own `x86-64-v3` spelling.
   function X86_Assembler_Architecture
     (Level : Landin.Targets.Levels.Feature_Level) return String;

end Landin.Backend.Toolchain;
