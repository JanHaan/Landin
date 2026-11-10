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
     (Item : in out Landin.Testing.Context; Source : String;
      Options : Landin.Optimization.Options :=
        Landin.Optimization.Reference_Options) return String;
   function Emitted
     (Item : in out Landin.Testing.Context; Source : String;
      Options : Landin.Optimization.Options :=
        Landin.Optimization.Reference_Options) return String
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
         Options, Text, Report);
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

   procedure Compact_Homes (Item : in out Landin.Testing.Context);
   procedure Compact_Homes (Item : in out Landin.Testing.Context) is
      Text : U.Unbounded_String;
      Serial : Natural := 0;
      Refused : Boolean := False;
   begin
      Landin.Backend.Xtensa_Machine.Select_Word
        ("mv x10, x8" & LF & "li x18, 73" & LF & "call callee"
         & LF & "mv x28, x18" & LF & "mv x28, x31"
         & LF & "addi sp, sp, -32", Text, Serial,
         Frame_Bytes => 256, Scratch_Registers => True);
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), "add a8, a7, a8")
           and then Contains (U.To_String (Text), "s32i a8, a7, 0")
           and then Contains (U.To_String (Text), "l32i a10, a7, 0")
           and then Contains (U.To_String (Text), "s32i a14, a7, 76")
           and then Contains (U.To_String (Text), "l32i a8, a7, 76")
           and then Contains (U.To_String (Text), "add a11, a7, a11")
           and then Contains (U.To_String (Text), "mov a8, a6"),
         "CFA, call carriers, fifth result and outgoing backchain share"
         & " the compact home map without aliasing each other");
      begin
         Landin.Backend.Xtensa_Machine.Select_Word
           ("mv x26, x10", Text, Serial, Scratch_Registers => True);
      exception
         when Landin.Compiler_Defect => Refused := True;
      end;
      Landin.Testing.Check
        (Item, Refused, "an omitted logical word cannot alias a live home");
      Refused := False;
      begin
         Landin.Backend.Xtensa_Machine.Select_Word
           ("mv x8, x10", Text, Serial, Scratch_Registers => True);
      exception
         when Landin.Compiler_Defect => Refused := True;
      end;
      Landin.Testing.Check
        (Item, Refused, "a compact CFA write cannot alias an argument");
      Text := U.Null_Unbounded_String;
      Landin.Backend.Xtensa_Machine.Select_Word
        ("mv x3, x10" & LF & "mv x10, x8", Text, Serial);
      Landin.Testing.Check
        (Item, Contains (U.To_String (Text), "s32i a8, a7, 12")
           and then Contains (U.To_String (Text), "l32i a8, a7, 32")
           and then Contains (U.To_String (Text), "s32i a8, a7, 40"),
         "opaque assembly retains the complete original home map");
   end Compact_Homes;

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

   --  [1640]: a placement's alignment follows the section directive of
   --  its item, a zeroed datum's, an initialized one's, an immutable
   --  one's and a routine's, as one more directive line the native
   --  translation passes through at every profile; that line once
   --  reached the translator indented and was refused as an operation.
   procedure Placement_Alignment (Item : in out Landin.Testing.Context);
   procedure Placement_Alignment (Item : in out Landin.Testing.Context) is
      package Opt renames Landin.Optimization;
      HT : constant Character := ASCII.HT;
      Source : constant String :=
        "link(align: 256)" & LF & "mut zero_cell: [3]u8 = zeroed" & LF
        & "link(align: 64)" & LF & "mut data_cell: u32 = 5" & LF
        & "link(align: 32)" & LF & "table: [3]u8 = [1, 2, 3]" & LF
        & "link(align: 16)" & LF
        & "twice: (x: u32) -> (r: u32) =" & LF & "    r = x + x" & LF
        & "end twice" & LF
        & "use: () -> (r: u32) =" & LF
        & "    data_cell = data_cell + u32(table[2]) + u32(zero_cell[1])"
        & LF & "    r = twice(data_cell)" & LF & "end use" & LF;
      type Profile_List is array (Positive range <>) of Opt.Options;
      Profiles : constant Profile_List :=
        [(Opt.None, Opt.Off), (Opt.Size, Opt.Off), (Opt.Size, Opt.Auto),
         (Opt.Speed, Opt.Auto)];
   begin
      for Options of Profiles loop
         declare
            Text : constant String := Emitted (Item, Source, Options);
            Where : constant String :=
              " at " & Opt.Spelling (Options.Optimize) & "/"
              & Opt.Spelling (Options.Specialize);
         begin
            Landin.Testing.Check
              (Item, Contains (Text, """aw"",@nobits" & LF & HT
                               & ".balign 256" & LF)
                 and then Contains (Text, """aw"",@progbits" & LF & HT
                                    & ".balign 64" & LF)
                 and then Contains (Text, """a"",@progbits" & LF & HT
                                    & ".balign 32" & LF)
                 and then Contains (Text, """ax"",@progbits" & LF & HT
                                    & ".balign 16" & LF),
               "each placed item's section is followed by its alignment"
               & Where & LF & Text);
         end;
      end loop;
   end Placement_Alignment;

   --  D1110.  The window handlers store a caller's a0 to a3 below the
   --  callee's SP when the caller's window is taken and read them from
   --  below it at RETW, so the words go with SP around an outgoing area.
   --  Execution is the window-arguments control of both chips' lanes.
   procedure Outgoing_Area_Base_Save (Item : in out Landin.Testing.Context);
   procedure Outgoing_Area_Base_Save (Item : in out Landin.Testing.Context)
   is
      HT : constant Character := ASCII.HT;
      Text : constant String := Emitted
        (Item,
         "sum4: (a: u64, b: u64, c: u64, d: u64) -> (r: u64) =" & LF
         & "    r = a + b + c + d" & LF
         & "end sum4" & LF
         & "sum3: (a: u64, b: u64, c: u64) -> (r: u64) =" & LF
         & "    r = a + b + c" & LF
         & "end sum3" & LF
         & "report: (seed: u64) -> (r: u64) =" & LF
         & "    r = sum4(seed, 2, 3, 4) + sum3(seed, 2, 3)" & LF
         & "end report" & LF);
      function Moved (From, To : String) return String is
        (HT & "l32e a8, " & From & ", -16" & LF
         & HT & "s32e a8, " & To & ", -16" & LF
         & HT & "l32e a8, " & From & ", -8" & LF
         & HT & "s32e a8, " & To & ", -8" & LF
         & HT & "l32e a8, " & From & ", -4" & LF
         & HT & "s32e a8, " & To & ", -4" & LF);
      Down : constant String := Moved ("a7", "a1");
      Up : constant String := Moved ("a1", "a7");
      Down_At : constant Natural := Ada.Strings.Fixed.Index (Text, Down);
      Call_At : constant Natural :=
        Ada.Strings.Fixed.Index (Text, "call8 sum4");
      Up_At : constant Natural := Ada.Strings.Fixed.Index (Text, Up);
      Raised_At : constant Natural :=
        (if Up_At = 0 then 0
         else Ada.Strings.Fixed.Index
           (Text, HT & "mov a1, ", Up_At + Up'Length));
   begin
      Landin.Testing.Check
        (Item, Down_At > 0 and then Call_At > Down_At
           and then Up_At > Call_At and then Raised_At > Up_At
           and then Ada.Strings.Fixed.Index
             (Text (Call_At .. Up_At), HT & "mov a1, ") = 0,
         "the caller's base save goes down after SP and up before it"
         & LF & Text);
      Landin.Testing.Check
        (Item, Down_At > 0
           and then Text (Down_At - 18 .. Down_At - 1)
             = "s32e a11, a1, -12" & LF,
         "the copy down follows the lowered SP's own backchain word");
      Landin.Testing.Check
        (Item, Ada.Strings.Fixed.Count (Text, Down) = 1
           and then Ada.Strings.Fixed.Count (Text, Up) = 1,
         "a call whose arguments fit the registers moves nothing");
   end Outgoing_Area_Base_Save;

   --  An interrupt's entry and return leave the firmware's interrupt
   --  context in EXCSAVE1, so the switch masks before it names its own.
   procedure Switch_Masks_First (Item : in out Landin.Testing.Context);
   procedure Switch_Masks_First (Item : in out Landin.Testing.Context) is
      HT : constant Character := ASCII.HT;
      Text : constant String := Emitted
        (Item,
         "mut backing: [4096]u8 = zeroed" & LF
         & "mut main_saved: usize = 0" & LF
         & "mut fibre_saved: usize = 0" & LF
         & "fibre: (argument: usize) -> noreturn =" & LF
         & "    loop do" & LF
         & "        compiler.stack_switch(addr fibre_saved, main_saved)" & LF
         & "    end loop" & LF
         & "end fibre" & LF
         & "run: () -> none =" & LF
         & "    fibre_saved = compiler.stack_prepare(backing[0..<4096],"
         & " fibre, 7)" & LF
         & "    compiler.stack_switch(addr main_saved, fibre_saved)" & LF
         & "end run" & LF);
      Masked_At : constant Natural :=
        Ada.Strings.Fixed.Index (Text, HT & "rsil a0, 15" & LF);
      Named_At : constant Natural :=
        Ada.Strings.Fixed.Index (Text, HT & "wsr a1, EXCSAVE1" & LF);
   begin
      Landin.Testing.Check
        (Item, Masked_At > 0 and then Named_At > Masked_At
           and then Ada.Strings.Fixed.Count (Text, "wsr a1, EXCSAVE1") = 1,
         "interrupts are masked before EXCSAVE1 holds the switch's context"
         & LF & Text);
      Landin.Testing.Check
        (Item, Named_At > 0
           and then Ada.Strings.Fixed.Index
             (Text (Text'First .. Named_At), "rsr a0, EXCSAVE1") = 0,
         "nothing reads the context register before it is written");
   end Switch_Masks_First;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "xtensa backend", "an outgoing area carries the base save",
         Outgoing_Area_Base_Save'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "the stack switch masks before its context",
         Switch_Masks_First'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "a placement's alignment is emitted",
         Placement_Alignment'Access);
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
        (Into, "xtensa backend", "compact homes preserve native boundaries",
         Compact_Homes'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "local jumps retain arbitrary range fallback",
         Jump_Ranges'Access);
      Landin.Testing.Register
        (Into, "xtensa backend", "opaque assembly retains range and homes",
         Assembly_Ranges'Access);
   end Register;
end Landin.Tests.Xtensa_Backend_Suite;
