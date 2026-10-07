--  Which target's corpus a run of the test program executes.
--
--  A run executes the corpus of one product target: the fixtures whose
--  `targets:` name it, compiled for its description and run on this host
--  or through the runner named for it.  It is the compiler's own host's
--  description unless `landin_tests --target=NAME` names another (D257), so
--  a run on Linux arm64 is that lane's without being told, and nothing here
--  asks the machine what it is: the triplet is the one the harness was built
--  for, as `refine`'s own default is.
--
--  A lane that is not the host's is a cross run: every compilation names
--  its target, and an executable runs through `--runner=PROGRAM`, an
--  emulator such as qemu-aarch64, or not at all.  `--toolchain=DRIVER`
--  names the C driver that links it when the target's own triplet driver is
--  not the one this host has.  The transcript says which lane ran and how.

with Landin.Platform;
with Landin.Targets;

package Landin.Testing.Lanes is

   --  Select by `refine`'s own name for the target; False if it names none
   --  or names one with no product lane.
   function Select_Target (Name : String) return Boolean;

   procedure Select_Runner (Program : String);

   procedure Select_Toolchain (Driver : String);

   --  The lane's description.  Raises Compiler_Defect if no target was
   --  selected and this host has no description of its own.
   function Target return Landin.Targets.Target_Facts;

   function Has_Target return Boolean;

   --  The name `refine --target=` takes for the lane.
   function Target_Name return String;

   --  The label a fixture's `targets:` names for the lane: `linux-x86-64`,
   --  `linux-arm64`, `macos-arm64`, `freebsd-x86-64`, `freebsd-arm64`
   --  or `cortex-m`.
   function Fixture_Label return String;

   --  Whether a fixture whose `targets:` is TARGETS belongs to the lane.
   function Applies (Targets : String) return Boolean;

   --  Whether the lane is the host's own, so a compilation may leave its
   --  target to the default and an executable runs directly.
   function Is_Native return Boolean;

   function Runner return String;

   function Toolchain return String;

   --  The arguments that select the lane for `refine`: none on the native
   --  lane, `--target=NAME` on any other.
   function Target_Arguments return Landin.Platform.Path_List;

   --  One line for the transcript naming the lane, and on a cross run the
   --  runner and toolchain.
   function Describe return String;

end Landin.Testing.Lanes;
