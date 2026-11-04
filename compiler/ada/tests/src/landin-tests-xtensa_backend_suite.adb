with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend.Xtensa;
with Landin.Backend.Xtensa_Machine;
with Landin.Backend.Site_Counts;
with Landin.Build_Reports;
with Landin.Optimization;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;

package body Landin.Tests.Xtensa_Backend_Suite is
   package U renames Ada.Strings.Unbounded;
   LF : constant Character := ASCII.LF;
   use type Landin.Source.Source_Id;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;

   function Contains (Text, Part : String) return Boolean
     is (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Emitted
     (Item : in out Landin.Testing.Context; Source : String) return String;
   function Emitted
     (Item : in out Landin.Testing.Context; Source : String) return String
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Xtensa);
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "xtensa.ldn", Source);
      Text : U.Unbounded_String;
      Report : Landin.Build_Reports.Report;
      Ran : Natural;
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 5, "five stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "Xtensa source checks");
      if Landin.Stages.Failed (Work) then return ""; end if;
      Landin.Backend.Xtensa.Emit
        (Landin.Stages.Code (Work).all,
         Landin.Stages.Meanings (Work).all,
         Landin.Stages.Identities (Work).all,
         Landin.Stages.Target (Work),
         Landin.Optimization.Reference_Options, Text, Report);
      return U.To_String (Text);
   end Emitted;

   --  End-to-end selection, including helper ABI boundaries. Execution of
   --  these operations belongs to both chips' freestanding corpus lanes.
   procedure Windowed_Pairs (Item : in out Landin.Testing.Context);
   procedure Windowed_Pairs (Item : in out Landin.Testing.Context) is
      Text : constant String := Emitted
        (Item,
         "wide: (a: u64, b: u64) -> (r: u64) =" & LF
         & "    r = (a * b) / b" & LF
         & "end wide" & LF
         & "float_add: (a: f64, b: f64) -> (r: f64) =" & LF
         & "    r = a + b" & LF
         & "end float_add" & LF
         & "caller: () -> (r: u64) =" & LF
         & "    r = wide(12, 3)" & LF
         & "end caller" & LF);
   begin
      Landin.Testing.Check
        (Item, Contains (Text, "entry a1, ")
           and then Contains (Text, "retw")
           and then Contains (Text, "mov a7, a1"),
         "all framed routines use the windowed convention and fixed base");
      Landin.Testing.Check
        (Item, Contains (Text, "muluh ")
           and then Contains (Text, "call8 __udivdi3")
           and then Contains (Text, "call8 __adddf3"),
         "wide integer and software float operations retain native helpers");
      Landin.Testing.Check
        (Item, not Contains (Text, "call0")
           and then not Contains (Text, "(sp)")
           and then not Contains (Text, ".option "),
         "the assembler receives only Xtensa instructions and directives");
   end Windowed_Pairs;

   procedure Assembly_Snapshots (Item : in out Landin.Testing.Context);
   procedure Assembly_Snapshots (Item : in out Landin.Testing.Context) is
      Text : constant String := Emitted
        (Item,
         "f: (v: u32) -> (r: u32) =" & LF
         & "    r = assembler.block(""add {r}, {v}, {v}""," & LF
         & "        in v: u32 at a10 = v, out r: u32 at a8," & LF
         & "        out _ at a9)" & LF
         & "end f" & LF);
   begin
      Landin.Testing.Check
        (Item, Contains (Text, "add a8, a10, a10")
           and then Contains (Text, "s32i a8, a7, 160")
           and then Contains (Text, "l32i a10, a7, 168"),
         "input assignment and output capture protect fixed scratch operands");
   end Assembly_Snapshots;

   procedure Native_Word_Accounting (Item : in out Landin.Testing.Context);
   procedure Native_Word_Accounting (Item : in out Landin.Testing.Context) is
      Text : U.Unbounded_String;
      Serial : Natural := 0;
      Counter : Landin.Backend.Site_Counts.Counter
        (Landin.Backend.Site_Counts.Xtensa);
      Stats : Landin.Build_Reports.Routine_Statistics;
   begin
      Landin.Backend.Xtensa_Machine.Select_Word
        ("lw x5, -48(x8)" & LF & "call callee" & LF
         & "sw x5, -48(x8)", Text, Serial);
      Landin.Backend.Site_Counts.Add_Lines (Counter, U.To_String (Text));
      Landin.Backend.Site_Counts.Fill (Counter, Stats);
      Landin.Testing.Check_Equal
        (Item, Stats.Direct_Calls, 1, "windowed calls are counted");
      Landin.Testing.Check
        (Item, Stats.Stack_Loads >= 8 and then Stats.Stack_Stores >= 4,
         "native frame traffic includes scratch homes and ABI carriers");
   end Native_Word_Accounting;

   procedure Frame_Offsets (Item : in out Landin.Testing.Context);
   procedure Frame_Offsets (Item : in out Landin.Testing.Context) is
      Text : U.Unbounded_String;
      Serial : Natural := 0;
   begin
      Landin.Backend.Xtensa_Machine.Select_Word
        ("lw x5, -48(x8)" & LF & "sw x5, -52(x8)" & LF
         & "lw x6, 1020(x8)" & LF & "lw x7, -47(x8)",
         Text, Serial, Frame_Bytes => 256);
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), "l32i a10, a7, 208")
           and then Contains (U.To_String (Text), "s32i a8, a7, 204"),
         "encodable CFA homes address the fixed base directly");
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), "movi a11, 1020")
           and then Contains (U.To_String (Text), "movi a11, -47"),
         "out-of-range and unaligned offsets retain computed addresses");
   end Frame_Offsets;

   procedure Register_Homes (Item : in out Landin.Testing.Context);
   procedure Register_Homes (Item : in out Landin.Testing.Context) is
      Text : U.Unbounded_String;
      Serial : Natural := 0;
   begin
      Landin.Backend.Xtensa_Machine.Select_Word
        ("lw x5, -48(x8)" & LF & "call __udivdi3" & LF
         & "sw x5, -52(x8)", Text, Serial,
         Frame_Bytes => 256, Scratch_Registers => True);
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), "l32i a2, a7, 208")
           and then Contains (U.To_String (Text), "call8 __udivdi3")
           and then Contains (U.To_String (Text), "s32i a2, a7, 204"),
         "scratch stays in the caller window across a helper call");
   end Register_Homes;

   procedure Jump_Ranges (Item : in out Landin.Testing.Context);
   procedure Jump_Ranges (Item : in out Landin.Testing.Context) is
      Text : U.Unbounded_String;
      Serial : Natural := 0;
   begin
      Landin.Backend.Xtensa_Machine.Select_Word
        ("j .Lnear", Text, Serial);
      U.Append (Text, ".Lnear:" & LF);
      Landin.Backend.Xtensa_Machine.Select_Word
        ("j .Lfar", Text, Serial);
      for Index in 1 .. 11_000 loop
         U.Append (Text, ASCII.HT & "nop" & LF);
      end loop;
      U.Append (Text, ".Lfar:" & LF);
      Landin.Backend.Xtensa_Machine.Compact_Jumps (Text, 1);
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), ASCII.HT & "j .Lnear"),
         "a proved local distance uses native J");
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), "movi a10, .Lfar")
           and then Contains (U.To_String (Text), "jx a10"),
         "an unproved distance retains an arbitrary-range jump");
   end Jump_Ranges;

   procedure Assembly_Ranges (Item : in out Landin.Testing.Context);
   procedure Assembly_Ranges (Item : in out Landin.Testing.Context) is
      Text : constant String := Emitted
        (Item,
         "f: (v: u32) -> (r: u32) =" & LF
         & "    assembler.block(""nop"")" & LF
         & "    r = if v == 0 then 1 else 2 end if" & LF
         & "end f" & LF);
   begin
      Landin.Testing.Check
        (Item, Contains (Text, "jx a10")
           and then not Contains (Text, ASCII.HT & "j .L"),
         "any opaque source assembly disables distance-based compaction");
      Landin.Testing.Check
        (Item, Contains (Text, "s32i a10, a7, 20"),
         "opaque source assembly retains all logical scratch homes");
   end Assembly_Ranges;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "xtensa backend", "windowed routines carry paired scalars",
         Windowed_Pairs'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "assembly captures scratch register outputs",
         Assembly_Snapshots'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "native word traffic and calls are counted",
         Native_Word_Accounting'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "fixed frame offsets retain range fallback",
         Frame_Offsets'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "scratch survives a helper window",
         Register_Homes'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "local jumps retain arbitrary range fallback",
         Jump_Ranges'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "opaque assembly retains range and homes",
         Assembly_Ranges'Access);
   end Register;
end Landin.Tests.Xtensa_Backend_Suite;
