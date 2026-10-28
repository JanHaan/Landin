with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;

--  D447's stack-depth report (D467, D468), through the driver on a fake
--  host: the frames and depths of a closed graph on every native target,
--  what a switch and a failed check cost, each kind of opening named where
--  it is, the same bytes for the same program, and the refusals.
package body Landin.Tests.Stack_Report_Suite is

   package US renames Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   type Target_Name is access constant String;
   Native : constant array (Positive range <>) of Target_Name :=
     [new String'("linux-x86-64"), new String'("linux-arm64"),
      new String'("linux-rv64"), new String'("cortex-m0")];

   --  A program emitted as assembly for Target, and the report it wrote.
   --  Linux links with libc so that no platform/linux is needed from a
   --  library this fake host does not hold.
   function Report
     (Item       : in out Landin.Testing.Context;
      Program    : String;
      Target     : String;
      Optimize   : String := "none";
      Specialize : String := "off";
      Source     : String := "main.ldn";
      Output     : String := "out.s") return String;

   function Report
     (Item       : in out Landin.Testing.Context;
      Program    : String;
      Target     : String;
      Optimize   : String := "none";
      Specialize : String := "off";
      Source     : String := "main.ldn";
      Output     : String := "out.s") return String
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      Result : Landin.Driver.Outcome;
   begin
      Host.Add_File (Source, Program);
      Args.Append ("--target=" & Target);
      if Target /= "cortex-m0" then
         Args.Append ("--link=libc");
      end if;
      Args.Append ("--optimize=" & Optimize);
      Args.Append ("--specialize=" & Specialize);
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append (Output);
      Args.Append ("--stack-report=stack.json");
      Args.Append (Source);
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Landin.Testing.Check_Equal
        (Item, Result.Status, Landin.Driver.Status_Success,
         Target & " emits with a stack report: "
         & US.To_String (Result.Report));
      return Host.Written ("stack.json");
   end Report;

   --  The one line of the report that is Name's routine.
   function Row (Text : String; Name : String) return String;

   function Row (Text : String; Name : String) return String is
      At_Name : constant Natural := Ada.Strings.Fixed.Index
        (Text, "{""item"":", Ada.Strings.Fixed.Index
           (Text, """routines"":"));
      Found : Natural;
      First, Last : Natural;
   begin
      if At_Name = 0 then
         return "";
      end if;
      Found := Ada.Strings.Fixed.Index
        (Text, """name"":""" & Name & """", At_Name);
      if Found = 0 then
         return "";
      end if;
      First := Found;
      while First > Text'First and then Text (First - 1) /= LF loop
         First := First - 1;
      end loop;
      Last := Found;
      while Last < Text'Last and then Text (Last + 1) /= LF loop
         Last := Last + 1;
      end loop;
      return Text (First .. Last);
   end Row;

   --  The number a field of a row holds, or -1 when it has none.
   function Field (Text : String; Name : String) return Integer;

   function Field (Text : String; Name : String) return Integer is
      Key : constant String := """" & Name & """:";
      At_Key : constant Natural := Ada.Strings.Fixed.Index (Text, Key);
      Value : Integer := 0;
      Index : Natural;
   begin
      if At_Key = 0 then
         return -1;
      end if;
      Index := At_Key + Key'Length;
      while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
         Value := Value * 10
           + (Character'Pos (Text (Index)) - Character'Pos ('0'));
         Index := Index + 1;
      end loop;
      return Value;
   end Field;

   Closed_Program : constant String :=
     "leaf: (x: u32) -> (y: u32) =" & LF
     & "    y = x" & LF
     & "end leaf" & LF
     & LF
     & "middle: (x: u32) -> (y: u32) =" & LF
     & "    y = leaf(x)" & LF
     & "end middle" & LF
     & LF
     & "public main: () -> (code: i32) =" & LF
     & "    _ = middle(7)" & LF
     & "    code = 0" & LF
     & "end main" & LF;

   --  Each routine's own frame is the backend's, from the stack pointer
   --  its caller had before the call: x86-64's return address and frame
   --  pointer, arm64's and RV64's frame record, Cortex-M0's pushed
   --  registers, the reference profile's frame and the area a call
   --  reserves.  The depth is the frame plus the deepest callee's.
   procedure A_Closed_Graph_On_Every_Target
     (Item : in out Landin.Testing.Context);

   procedure A_Closed_Graph_On_Every_Target
     (Item : in out Landin.Testing.Context)
   is
      type Expected is record
         Leaf, Middle, Main : Natural;
      end record;
      Frames : constant array (Native'Range) of Expected :=
        [(32, 48, 48), (32, 48, 48), (112, 128, 128), (28, 56, 48)];
   begin
      for Index in Native'Range loop
         declare
            Target : constant String := Native (Index).all;
            Text : constant String :=
              Report (Item, Closed_Program, Target);
            Leaf : constant String := Row (Text, "main.leaf");
            Middle : constant String := Row (Text, "main.middle");
            Main : constant String := Row (Text, "main.main");
            Want : constant Expected := Frames (Index);
         begin
            Landin.Testing.Check
              (Item, Contains (Text, "{""format"":""landin-stack-report-1"","
                 & """target"":""" & Target & """"),
               Target & ": the report names its format and target");
            Landin.Testing.Check_Equal
              (Item, Field (Leaf, "frame_bytes"), Want.Leaf,
               Target & ": the leaf's frame");
            Landin.Testing.Check_Equal
              (Item, Field (Leaf, "depth_bytes"), Want.Leaf,
               Target & ": a leaf's depth is its frame");
            Landin.Testing.Check_Equal
              (Item, Field (Middle, "frame_bytes"), Want.Middle,
               Target & ": the caller's frame, its call's area included");
            Landin.Testing.Check_Equal
              (Item, Field (Middle, "depth_bytes"), Want.Middle + Want.Leaf,
               Target & ": a caller's depth adds its callee's");
            Landin.Testing.Check_Equal
              (Item, Field (Main, "frame_bytes"), Want.Main,
               Target & ": main's frame");
            Landin.Testing.Check_Equal
              (Item, Field (Main, "depth_bytes"),
               Want.Main + Want.Middle + Want.Leaf,
               Target & ": main's depth is the whole chain");
            Landin.Testing.Check
              (Item, Contains (Main, """closed"":true")
                 and then Contains (Main, """openings"":[]")
                 and then Contains
                   (Main, """path"":[""main.main"",""main.middle"","
                    & """main.leaf""]"),
               Target & ": a closed graph says so and names its path: "
               & Main);
            Landin.Testing.Check
              (Item, Contains (Leaf, """file"":""main.ldn"",""line"":1,"
                 & """column"":1"),
               Target & ": a routine is named where it is declared");
         end;
      end loop;
   end A_Closed_Graph_On_Every_Target;

   Switch_Program : constant String :=
     "mut main_saved: usize = 0" & LF
     & "mut fibre_saved: usize = 0" & LF
     & "mut backing: [1024]u8 = zeroed" & LF
     & LF
     & "fibre: (argument: usize) -> noreturn =" & LF
     & "    _ = argument" & LF
     & "    compiler.stack_switch(addr fibre_saved, main_saved)" & LF
     & "    compiler.unreachable()" & LF
     & "end fibre" & LF
     & LF
     & "public main: () -> (code: i32) =" & LF
     & "    fibre_saved = compiler.stack_prepare(backing[0..<1024], fibre,"
     & " 0)" & LF
     & "    compiler.stack_switch(addr main_saved, fibre_saved)" & LF
     & "    code = 0" & LF
     & "end main" & LF;

   --  A switch is not a call into the context it resumes: it costs what
   --  the switch routine saves on the leaving stack.  The first frame a
   --  prepare lays, and where the entry starts below a stack's top, are
   --  the target's, for whoever sizes a backing (D461), as are the margin
   --  a prepared stack's limit keeps above its base and the largest frame
   --  or call area no check covers (D472).
   procedure A_Switch_Costs_Its_Frame
     (Item : in out Landin.Testing.Context);

   procedure A_Switch_Costs_Its_Frame
     (Item : in out Landin.Testing.Context)
   is
      type Expected is record
         Switch, Prepared, Entry_Below, Margin, Unchecked : Natural;
      end record;
      Facts : constant array (Native'Range) of Expected :=
        [(64, 64, 0, 640, 64), (176, 176, 0, 640, 64),
         (208, 208, 0, 768, 64), (48, 48, 0, 384, 64)];
   begin
      for Index in Native'Range loop
         declare
            Target : constant String := Native (Index).all;
            Text : constant String := Report (Item, Switch_Program, Target);
            Fibre : constant String := Row (Text, "main.fibre");
            Want : constant Expected := Facts (Index);
         begin
            Landin.Testing.Check_Equal
              (Item, Field (Text, "switch_bytes"), Want.Switch,
               Target & ": the switch routine's frame");
            Landin.Testing.Check_Equal
              (Item, Field (Text, "prepared_bytes"), Want.Prepared,
               Target & ": the prepared first frame");
            Landin.Testing.Check_Equal
              (Item, Field (Text, "entry_bytes"), Want.Entry_Below,
               Target & ": where the entry starts below the top");
            Landin.Testing.Check_Equal
              (Item, Field (Text, "margin_bytes"), Want.Margin,
               Target & ": the margin a prepared stack's limit keeps");
            Landin.Testing.Check_Equal
              (Item, Field (Text, "unchecked_bytes"), Want.Unchecked,
               Target & ": the largest frame no check covers");
            Landin.Testing.Check
              (Item, Contains (Fibre, """switches"":true")
                 and then Contains (Fibre, """address_taken"":true")
                 and then Contains
                   (Fibre, """path"":[""main.fibre"",""(switch)""]"),
               Target & ": the fibre's deepest point is its switch: "
               & Fibre);
            Landin.Testing.Check_Equal
              (Item, Field (Fibre, "depth_bytes"),
               Field (Fibre, "frame_bytes") + Want.Switch,
               Target & ": a switch adds its frame, not the resumed stack");
         end;
      end loop;
   end A_Switch_Costs_Its_Frame;

   Trap_Program : constant String :=
     "leaf: (x: u32) -> (y: u32) =" & LF
     & "    y = x + 1" & LF
     & "end leaf" & LF
     & LF
     & "public main: () -> (code: i32) =" & LF
     & "    _ = leaf(7)" & LF
     & "    code = 0" & LF
     & "end main" & LF;

   --  A failed check calls D361's report on the stack it failed on, which
   --  the depth counts; on Cortex-M0 with no handler it is a trap
   --  instruction, whose exception frame is D461's.
   procedure A_Failed_Check_Counts
     (Item : in out Landin.Testing.Context);

   procedure A_Failed_Check_Counts
     (Item : in out Landin.Testing.Context)
   is
      Hosted : constant String :=
        Report (Item, Trap_Program, "linux-x86-64");
      Leaf : constant String := Row (Hosted, "main.leaf");
      Firmware : constant String :=
        Report (Item, Trap_Program, "cortex-m0");
      Bare : constant String := Row (Firmware, "main.leaf");
   begin
      Landin.Testing.Check
        (Item, Contains (Hosted, """trap"":{""calls"":""report"","
           & """depth_bytes"":8,""closed"":true"),
         "Linux x86-64's report is a return address and a system call");
      Landin.Testing.Check
        (Item, Contains (Leaf, """traps"":true")
           and then Contains (Leaf, """path"":[""main.leaf"",""(trap)""]"),
         "a checked add's trap is the leaf's deepest point: " & Leaf);
      Landin.Testing.Check_Equal
        (Item, Field (Leaf, "depth_bytes"), Field (Leaf, "frame_bytes") + 8,
         "the report adds to the frame it failed in");
      Landin.Testing.Check
        (Item, Contains (Firmware, """trap"":{""calls"":""none"","
           & """depth_bytes"":0")
           and then Contains (Bare, """traps"":false"),
         "firmware with no handler traps without a call: " & Bare);
   end A_Failed_Check_Counts;

   Open_Program : constant String :=
     "counter: type = concept (provider: type)" & LF
     & "    total: (self: provider) -> (sum: u32)" & LF
     & "end counter" & LF
     & LF
     & "tally: type = struct" & LF
     & "    sum: u32" & LF
     & "end tally" & LF
     & LF
     & "tally_total: (self: tally) -> (sum: u32) =" & LF
     & "    sum = self.sum" & LF
     & "end tally_total" & LF
     & LF
     & "tally is counter (total: tally_total)" & LF
     & LF
     & "extern(c) labs: (value: i64) -> (result: i64)" & LF
     & LF
     & "apply: (f: (x: u32) -> (y: u32), x: u32) -> (y: u32) =" & LF
     & "    y = f(x)" & LF
     & "end apply" & LF
     & LF
     & "erased: (item: any counter) -> (sum: u32) =" & LF
     & "    sum = item.total()" & LF
     & "end erased" & LF
     & LF
     & "through: (t: type is counter, item: t) -> (sum: u32) =" & LF
     & "    sum = t.total(item)" & LF
     & "end through" & LF
     & LF
     & "down: (n: u32) -> (y: u32) =" & LF
     & "    y = 0" & LF
     & "    return when n == 0" & LF
     & "    y = down(n - 1)" & LF
     & "end down" & LF
     & LF
     & "pushing: () -> none =" & LF
     & "    assembler.block(""""""" & LF
     & "        pushq %rax" & LF
     & "        popq %rax" & LF
     & "        """""")" & LF
     & "end pushing" & LF
     & LF
     & "identity: (x: u32) -> (y: u32) =" & LF
     & "    y = x" & LF
     & "end identity" & LF
     & LF
     & "public main: () -> (code: i32) =" & LF
     & "    held: tally = (sum: 3)" & LF
     & "    _ = apply(identity, 1)" & LF
     & "    _ = erased(any(addr held))" & LF
     & "    _ = through(held)" & LF
     & "    _ = down(2)" & LF
     & "    _ = labs(-4)" & LF
     & "    pushing()" & LF
     & "    code = 0" & LF
     & "end main" & LF;

   --  D468: each kind of opening, named with the routine it is in and
   --  where, and every routine that reaches one is open.  At the
   --  reference profile with specialization off, the generic's call stays
   --  a call through its table.
   procedure Each_Opening_Is_Named
     (Item : in out Landin.Testing.Context);

   procedure Each_Opening_Is_Named
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String := Report (Item, Open_Program, "linux-x86-64");
      Main : constant String := Row (Text, "main.main");

      procedure Opened (Kind, Within, Where : String; Callee : String := "");

      procedure Opened (Kind, Within, Where : String; Callee : String := "")
      is
      begin
         Landin.Testing.Check
           (Item, Contains (Text, """kind"":""" & Kind & """,""routine"":"""
              & Within & """,""file"":""main.ldn""," & Where
              & (if Callee = "" then "}"
                 else ",""callee"":""" & Callee & """}")),
            "a " & Kind & " opening is named in " & Within & ": " & Text);
      end Opened;
   begin
      Opened ("function value", "main.apply", """line"":18,""column"":9");
      Opened ("any", "main.erased", """line"":22,""column"":11");
      Opened ("evidence", "main.through", """line"":26,""column"":11");
      Opened ("recursion", "main.down", """line"":32,""column"":9",
              "main.down");
      Opened ("assembly", "main.pushing", """line"":36,""column"":5");
      Opened ("foreign", "main.main", """line"":52,""column"":9",
              "main.labs");
      Landin.Testing.Check
        (Item, Contains (Main, """closed"":false")
           and then Contains (Main, """openings"":[1,2,3,4,5,6]"),
         "main reaches every opening: " & Main);
      Landin.Testing.Check
        (Item, Contains (Row (Text, "main.tally_total"), """closed"":true")
           and then Contains
             (Row (Text, "main.tally_total"), """address_taken"":true")
           and then Contains (Row (Text, "main.identity"),
                              """address_taken"":true"),
         "a routine reached only through a table or a value is closed, and"
         & " its address is taken");
      Landin.Testing.Check_Equal
        (Item, Field (Row (Text, "main.down"), "depth_bytes"),
         Field (Row (Text, "main.down"), "frame_bytes") + 8,
         "a recursive routine's depth is what the rest of its graph closes,"
         & " here its trap");
   end Each_Opening_Is_Named;

   --  A Cortex-M0 division calls a runtime helper the toolchain links,
   --  whose stack the compiler does not know.
   procedure A_Helper_Opens_The_Graph
     (Item : in out Landin.Testing.Context);

   procedure A_Helper_Opens_The_Graph
     (Item : in out Landin.Testing.Context)
   is
      Program : constant String :=
        "mut seen: u32 = 7" & LF
        & LF
        & "ratio: (a: u32, b: u32) -> (q: u32) =" & LF
        & "    q = a / b" & LF
        & "end ratio" & LF
        & LF
        & "public main: () -> (code: i32) =" & LF
        & "    seen = ratio(seen, seen + 1)" & LF
        & "    code = 0" & LF
        & "end main" & LF;
      Text : constant String := Report (Item, Program, "cortex-m0");
   begin
      Landin.Testing.Check
        (Item, Contains (Text, """kind"":""helper"",""routine"":"""
           & "main.ratio"",""file"":""main.ldn"",""line"":3")
           and then Contains (Row (Text, "main.main"), """closed"":false"),
         "a helper call opens its routine's graph and its callers': "
         & Text);
   end A_Helper_Opens_The_Graph;

   --  The report holds no path, clock or output name: the same program
   --  read from another directory and emitted elsewhere gives the same
   --  bytes.
   procedure The_Same_Program_Gives_The_Same_Report
     (Item : in out Landin.Testing.Context);

   procedure The_Same_Program_Gives_The_Same_Report
     (Item : in out Landin.Testing.Context)
   is
      First : constant String := Report
        (Item, Open_Program, "linux-x86-64", "size", "auto");
      Second : constant String := Report
        (Item, Open_Program, "linux-x86-64", "size", "auto",
         Source => "elsewhere/main.ldn", Output => "built/other.s");
   begin
      Landin.Testing.Check
        (Item, First'Length > 0 and then First = Second,
         "one program gives one report");
   end The_Same_Program_Gives_The_Same_Report;

   --  The report measures emitted frames, so it needs emission; it is
   --  one path, and it may not overwrite another output or a source.
   procedure A_Stack_Report_Needs_Emitted_Code
     (Item : in out Landin.Testing.Context);

   procedure A_Stack_Report_Needs_Emitted_Code
     (Item : in out Landin.Testing.Context)
   is
      function Refusal (Options : Landin.Platform.Path_List) return String;

      function Refusal (Options : Landin.Platform.Path_List) return String
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List := Options;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File ("main.ldn", Closed_Program);
         Args.Prepend ("--target=cortex-m0");
         Args.Append ("main.ldn");
         Result := Landin.Driver.Execute (Args, Host, Tools);
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Misuse,
            "a misused stack report is misuse: "
            & US.To_String (Result.Report));
         Landin.Testing.Check_Equal
           (Item, Host.Write_Count, 0, "a refused request writes nothing");
         return US.To_String (Result.Report);
      end Refusal;

      Unemitted, As_IR, Twice, Over_Output, Over_Source :
        Landin.Platform.Path_List;
   begin
      Unemitted.Append ("--stack-report=stack.json");
      Landin.Testing.Check
        (Item, Contains (Refusal (Unemitted), "--stack-report measures the"
           & " frames of emitted machine code: add --emit=asm or"
           & " --emit=exe"),
         "a check has no frames to report");
      As_IR.Append ("--emit=ir");
      As_IR.Append ("--stack-report=stack.json");
      Landin.Testing.Check
        (Item, Contains (Refusal (As_IR), "--stack-report measures"),
         "the IR has no frames either");
      Twice.Append ("--emit=asm");
      Twice.Append ("--stack-report=a.json");
      Twice.Append ("--stack-report=b.json");
      Landin.Testing.Check
        (Item, Contains (Refusal (Twice), "--stack-report"),
         "a repeated stack report is refused");
      Over_Output.Append ("--emit=asm");
      Over_Output.Append ("-o");
      Over_Output.Append ("out.s");
      Over_Output.Append ("--stack-report=out.s");
      Landin.Testing.Check
        (Item, Contains (Refusal (Over_Output),
           "stack report collides with another output: out.s"),
         "a stack report does not overwrite the assembly");
      Over_Source.Append ("--emit=asm");
      Over_Source.Append ("--stack-report=main.ldn");
      Landin.Testing.Check
        (Item, Contains (Refusal (Over_Source),
           "stack report collides with source: main.ldn"),
         "a stack report does not overwrite a source");
   end A_Stack_Report_Needs_Emitted_Code;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "stack report", "a closed graph on every target",
         A_Closed_Graph_On_Every_Target'Access);
      Landin.Testing.Register
        (Into, "stack report", "a switch costs its frame",
         A_Switch_Costs_Its_Frame'Access);
      Landin.Testing.Register
        (Into, "stack report", "a failed check counts",
         A_Failed_Check_Counts'Access);
      Landin.Testing.Register
        (Into, "stack report", "each opening is named",
         Each_Opening_Is_Named'Access);
      Landin.Testing.Register
        (Into, "stack report", "a helper opens the graph",
         A_Helper_Opens_The_Graph'Access);
      Landin.Testing.Register
        (Into, "stack report", "the same program gives the same report",
         The_Same_Program_Gives_The_Same_Report'Access);
      Landin.Testing.Register
        (Into, "stack report", "a stack report needs emitted code",
         A_Stack_Report_Needs_Emitted_Code'Access);
   end Register;

end Landin.Tests.Stack_Report_Suite;
