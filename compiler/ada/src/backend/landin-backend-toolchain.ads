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
--  There is deliberately no fallback to a bare `gcc`.  A host without the
--  selected driver cannot finish the target; substituting a host compiler
--  could hand ELF assembly to a Mach-O toolchain.  `Landin.Targets` keeps
--  the target explicit rather than inferring it from the host.
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

   --  Apple ld has no GNU exact-archive -l form. Ask the selected
   --  compiler driver to resolve each archive through its own search path.
   --  Linux names pass through unchanged. An unresolved archive fails here.
   procedure Resolve_Libraries
     (Facts : Landin.Targets.Target_Facts;
      Driver : String;
      Host : Landin.Platform.Filesystem'Class;
      Tools : Landin.Platform.Tool_Runner'Class;
      Libraries : in out Landin.Platform.Path_List;
      Result : out Landin.Platform.Tool_Result;
      Ready : out Boolean);

   --  The whole command line, in the order a reader would write it.
   --  Relative file operands beginning with '-' or '@' gain './' so the
   --  driver reads the named file rather than an option or response file.
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
      Level : Landin.Targets.Levels.Feature_Level)
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
      Full_Debug : Boolean := False)
      return Landin.Platform.Path_List;

   --  The GNU assembler's `-march=` for an x86-64 level: `generic64`, the
   --  psABI baseline, with each extension the level adds.  The pinned
   --  assembler does not accept the psABI's own `x86-64-v3` spelling.
   function X86_Assembler_Architecture
     (Level : Landin.Targets.Levels.Feature_Level) return String;

end Landin.Backend.Toolchain;
