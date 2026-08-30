--  How a target names its toolchain, and what [1970] requires of an entry.
--
--  These cases read command lines and never run one.  What this compiler
--  owns is the argv it hands a driver; whether that driver then assembles
--  and links is the driver's business, in the same way nothing here asserts
--  that GNU as understands `@function`.  The one case that runs a real
--  toolchain is the runtime fixture, and it is the only place a process is
--  started.

with Landin.Backend.Entry_Point;
with Landin.Backend.Toolchain;
with Landin.IR;
with Landin.Platform;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Capabilities;

package body Landin.Tests.Toolchain_Suite is

   use type Landin.IR.Item_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Capabilities.Backend_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;
   Lowerer  : aliased Landin.Stages.Lowering.Instance;

   LF : constant Character := Character'Val (10);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural)
   is
      Order   : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "entry.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
   end Lower;

   ------------------------------------------------------------------
   --  The triplet, and the driver it names
   ------------------------------------------------------------------

   --  Measured in the pinned image rather than recalled: the GNAT this
   --  repository pins installs itself as `x86_64-pc-linux-gnu-gcc` there.
   --  A target whose backend is No_Backend has no triplet, which is the
   --  postcondition on Triplet stated as a case.
   procedure A_Target_Names_Its_Toolchain
     (Item : in out Landin.Testing.Context);

   procedure A_Target_Names_Its_Toolchain
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check_Equal
        (Item,
         Landin.Targets.Capabilities.Triplet (Landin.Targets.Linux_X86_64),
         "x86_64-pc-linux-gnu",
         "the first target carries the triplet its toolchain uses");

      Landin.Testing.Check_Equal
        (Item,
         Landin.Backend.Toolchain.Driver_For
           (Landin.Targets.Linux_X86_64, ""),
         "x86_64-pc-linux-gnu-gcc",
         "the driver is the triplet with the GNU convention's suffix");

      Landin.Testing.Check_Equal
        (Item,
         Landin.Targets.Capabilities.Triplet (Landin.Targets.Synthetic_32),
         "",
         "a target with no backend names no toolchain");

      Landin.Testing.Check
        (Item,
         Landin.Targets.Capabilities.Backend_For
           (Landin.Targets.Synthetic_32)
         = Landin.Targets.Capabilities.No_Backend,
         "and that is the same fact its backend column states");

      Landin.Testing.Check_Equal
        (Item,
         Landin.Backend.Toolchain.Driver_For
           (Landin.Targets.Synthetic_32, ""),
         "",
         "so no driver can be named for it");
   end A_Target_Names_Its_Toolchain;

   --  A host that spells its triplet another way -- Debian's
   --  `x86_64-linux-gnu`, LLVM's `x86_64-unknown-linux-gnu` -- says so
   --  rather than being guessed at, which is why no alias table exists.
   procedure A_Named_Toolchain_Overrides_The_Convention
     (Item : in out Landin.Testing.Context);

   procedure A_Named_Toolchain_Overrides_The_Convention
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check_Equal
        (Item,
         Landin.Backend.Toolchain.Driver_For
           (Landin.Targets.Linux_X86_64, "x86_64-linux-gnu-gcc"),
         "x86_64-linux-gnu-gcc",
         "a named toolchain wins over the triplet");

      --  Even a target that names none can be finished if the caller
      --  knows a tool that can do it.
      Landin.Testing.Check_Equal
        (Item,
         Landin.Backend.Toolchain.Driver_For
           (Landin.Targets.Synthetic_32, "zig"),
         "zig",
         "and a target with no triplet can still be given one");
   end A_Named_Toolchain_Overrides_The_Convention;

   ------------------------------------------------------------------
   --  The command line
   ------------------------------------------------------------------

   --  mold is why `--linker` exists, and its own README is why it is a
   --  pass-through: all three documented ways to use it go through a
   --  compiler driver, because the crt objects and the dynamic loader's
   --  path live there.  So selecting a linker adds one argument and
   --  changes nothing else about the invocation.
   procedure A_Linker_Is_Passed_Through_The_Driver
     (Item : in out Landin.Testing.Context);

   procedure A_Linker_Is_Passed_Through_The_Driver
     (Item : in out Landin.Testing.Context)
   is
      Plain : constant Landin.Platform.Path_List :=
        Landin.Backend.Toolchain.Link_Arguments ("main.s", "main", "");
      Molded : constant Landin.Platform.Path_List :=
        Landin.Backend.Toolchain.Link_Arguments ("main.s", "main", "mold");
   begin
      --  Joined terminates every element, so the expectation does too.
      Landin.Testing.Check_Equal
        (Item, Natural (Plain.Length), 3, "three arguments and no more");
      Landin.Testing.Check_Equal
        (Item, Landin.Platform.Joined (Plain),
         "main.s" & LF & "-o" & LF & "main" & LF,
         "the plain invocation is the input, -o and the output");

      Landin.Testing.Check_Equal
        (Item, Natural (Molded.Length), 4, "the linker adds exactly one");
      Landin.Testing.Check_Equal
        (Item, Landin.Platform.Joined (Molded),
         "main.s" & LF & "-o" & LF & "main" & LF & "-fuse-ld=mold" & LF,
         "a named linker becomes -fuse-ld= and nothing else moves");
   end A_Linker_Is_Passed_Through_The_Driver;

   ------------------------------------------------------------------
   --  [1970]'s entry
   ------------------------------------------------------------------

   --  D12 lists "treat the return's name as immaterial" among the
   --  alternatives it did not take, so each of the five conditions is
   --  asked, and each of these programs fails exactly one of them.
   procedure The_Hosted_Entry_Is_One_Shape
     (Item : in out Landin.Testing.Context);

   procedure The_Hosted_Entry_Is_One_Shape
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Entry (Text : String; Found : Boolean; Why : String);

      procedure Check_Entry (Text : String; Found : Boolean; Why : String) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Ran  : Natural;
      begin
         Lower (Work, Text, Ran);
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "the program is accepted: " & Why);
         Landin.Testing.Check
           (Item,
            (Landin.Backend.Entry_Point.Hosted_Main
               (Landin.Stages.Code (Work).all,
                Landin.Stages.Meanings (Work).all,
                Landin.Stages.Identities (Work).all)
             /= Landin.IR.No_Item) = Found,
            Why);
      end Check_Entry;
   begin
      Check_Entry
        ("public main: () -> (code: i32) =" & LF
         & "    code = 0" & LF & "end main" & LF,
         True, "[1970]'s shape is the entry");

      Check_Entry
        ("main: () -> (code: i32) =" & LF
         & "    code = 0" & LF & "end main" & LF,
         False, "a main that is not public is not an entry");

      Check_Entry
        ("public start: () -> (code: i32) =" & LF
         & "    code = 0" & LF & "end start" & LF,
         False, "a public routine not named main is not an entry");

      Check_Entry
        ("public main: () -> (status: i32) =" & LF
         & "    status = 0" & LF & "end main" & LF,
         False, "the named return must be `code`");

      Check_Entry
        ("public main: () -> (code: u32) =" & LF
         & "    code = 0" & LF & "end main" & LF,
         False, "the named return must be i32");

      Check_Entry
        ("public main: (n: i32) -> (code: i32) =" & LF
         & "    code = n" & LF & "end main" & LF,
         False, "[1970]'s entry takes no arguments");
   end The_Hosted_Entry_Is_One_Shape;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "toolchain", "a target names its toolchain",
         A_Target_Names_Its_Toolchain'Access);
      Landin.Testing.Register
        (Into, "toolchain", "a named toolchain overrides the convention",
         A_Named_Toolchain_Overrides_The_Convention'Access);
      Landin.Testing.Register
        (Into, "toolchain", "a linker is passed through the driver",
         A_Linker_Is_Passed_Through_The_Driver'Access);
      Landin.Testing.Register
        (Into, "toolchain", "the hosted entry is one shape",
         The_Hosted_Entry_Is_One_Shape'Access);
   end Register;

end Landin.Tests.Toolchain_Suite;
