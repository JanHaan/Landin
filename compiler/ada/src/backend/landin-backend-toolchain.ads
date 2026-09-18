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
--  not in `ld`, and they differ per distribution.  Asking `gcc` to finish
--  the job is what keeps that knowledge out of this compiler; invoking a
--  linker directly would move every one of those paths in here, where no
--  paragraph of the specification could say what they are.
--
--  The driver is found by the GNU triplet prefix.  That convention is the
--  reason this needs no configuration in the environments that already
--  exist: `Landin.Targets.Capabilities.Triplet` carries the spelling, and
--  the pinned GNAT installs itself under it.  Measured rather than assumed
--  -- `x86_64-pc-linux-gnu-gcc` resolves inside the pinned Linux image, and
--  the same toolchain is `aarch64-apple-darwin24.6.0-gcc` on the macOS
--  host.
--
--  There is deliberately no fall back to a bare `gcc`.  A host whose
--  triplet-prefixed driver is absent is a host that cannot finish this
--  target, and reaching for whatever `gcc` names would, on the macOS
--  development host, hand ELF-only assembly to a toolchain that emits
--  Mach-O.  Making that a stated refusal costs one diagnostic; making it a
--  fallback would cost a host-detection rule this compiler has nowhere to
--  put -- `Landin.Targets`' whole reason for existing is that the host is
--  never asked what the target is.
--
--  Whether the named driver exists is not asked here either.  A tool that
--  cannot be started raises `External_Tool_Failed` from
--  `Landin.Platform.Tool_Runner`, which is already the interface's stated
--  line between a tool that could not be run and one that ran and failed,
--  so no PATH is searched twice.

with Landin.Platform;
with Landin.Targets;

package Landin.Backend.Toolchain is

   --  The program that turns assembly text into an executable.  `Named`
   --  overrides the convention for a host that spells its triplet
   --  differently, or that has no GNU toolchain at all; the empty string
   --  asks for the convention.  An empty result means the target names no
   --  toolchain and none was given, which is the one case that cannot be
   --  attempted rather than merely failing.
   --  Darwin retains the full source/assembly digest without filenames.
   --  ELF supplies the same digest through the GNU linker build-id option.
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
   function Assemble_Arguments
     (Assembly, Output : String; Facts : Landin.Targets.Target_Facts;
      Debug : Boolean := False)
      return Landin.Platform.Path_List;

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

end Landin.Backend.Toolchain;
