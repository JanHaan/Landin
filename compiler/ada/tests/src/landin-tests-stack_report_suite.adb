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

   --  D474: programs that select a panic handler, with core/panic beside
   --  them.  Prepares says whether the program holds a
   --  `compiler.stack_prepare`; Handler is the handler's body, or "" for
   --  a program that selects none.
   Panic_Core : constant String :=
     "public out_of_range: atom public overflow: atom "
     & "public bad_conversion: atom public unreachable: atom "
     & "public stack_exhausted: atom "
     & "public panic_kind: type = out_of_range | overflow | "
     & "bad_conversion | unreachable | stack_exhausted" & LF;

   Small_Handler : constant String :=
     "    seen = if site <> 0 then 42 else 5 end if" & LF
     & "    _ = kind" & LF;

   Large_Handler : constant String :=
     "    mut notes: [512]u8 = zeroed" & LF
     & "    mut index: usize = 0" & LF
     & "    while index < 512 do" & LF
     & "        notes[index] = 7" & LF
     & "        inc index" & LF
     & "    end while" & LF
     & "    seen = i32(notes[index - 1])" & LF
     & "    _ = kind" & LF
     & "    _ = site" & LF;

   Erased_Handler : constant String :=
     "    seen = i32(erased(any(addr held)))" & LF
     & "    _ = kind" & LF
     & "    _ = site" & LF;

   function Handler_Program
     (Handler : String; Prepares : Boolean) return String;

   function Handler_Program
     (Handler : String; Prepares : Boolean) return String
   is ("import core/panic" & LF
       & "counter: type = concept (provider: type)" & LF
       & "    total: (self: provider) -> (sum: u32)" & LF
       & "end counter" & LF
       & "tally: type = struct" & LF
       & "    sum: u32" & LF
       & "end tally" & LF
       & "tally_total: (self: tally) -> (sum: u32) =" & LF
       & "    sum = self.sum" & LF
       & "end tally_total" & LF
       & "tally is counter (total: tally_total)" & LF
       & "erased: (item: any counter) -> (sum: u32) =" & LF
       & "    sum = item.total()" & LF
       & "end erased" & LF
       & "mut held: tally = (sum: 3)" & LF
       & "mut memory: [2048]u8 = zeroed" & LF
       & "mut main_saved: usize = 0" & LF
       & "mut fibre_saved: usize = 0" & LF
       & "mut seen: i32 = 0" & LF
       & (if Handler = "" then ""
          else "public panic_handler: (kind: panic.panic_kind, site: u32)"
               & " -> noreturn =" & LF
               & Handler
               & "    compiler.stack_switch(addr fibre_saved, main_saved)"
               & LF
               & "    loop do" & LF
               & "    end loop" & LF
               & "end panic_handler" & LF)
       & "fibre: (argument: usize) -> noreturn =" & LF
       & "    seen = i32(argument) + i32(erased(any(addr held)))" & LF
       & "    compiler.stack_switch(addr fibre_saved, main_saved)" & LF
       & "    loop do" & LF
       & "    end loop" & LF
       & "end fibre" & LF
       & "public main: () -> (code: i32) =" & LF
       & (if Prepares
          then "    fibre_saved = compiler.stack_prepare(memory[0..<2048],"
               & " fibre, 3)" & LF
          else "    fibre_saved = 0" & LF)
       & "    compiler.stack_switch(addr main_saved, fibre_saved)" & LF
       & "    code = seen" & LF
       & "end main" & LF);

   type Handler_Outcome is record
      Status : Natural := 0;
      Said : US.Unbounded_String;
      Stack : US.Unbounded_String;
      Writes : Natural := 0;
   end record;

   --  The program emitted as assembly for Target at the reference
   --  profile, with a stack report.
   function Emit_Handler
     (Program : String; Target : String) return Handler_Outcome;

   function Emit_Handler
     (Program : String; Target : String) return Handler_Outcome
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      Result : Landin.Driver.Outcome;
      Outcome : Handler_Outcome;
   begin
      Host.Add_Directory ("app");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/core");
      Host.Add_Directory ("root/core/panic");
      Host.Add_File ("root/core/panic/panic.ldn", Panic_Core);
      Host.Add_File ("app/main.ldn", Program);
      Args.Append ("--root=root");
      Args.Append ("--target=" & Target);
      if Ada.Strings.Fixed.Index (Target, "linux") > 0 then
         Args.Append ("--link=libc");
      end if;
      Args.Append ("--optimize=none");
      Args.Append ("--specialize=off");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("out.s");
      Args.Append ("--stack-report=stack.json");
      Args.Append ("app");
      Result := Landin.Driver.Execute (Args, Host, Tools);
      Outcome.Status := Result.Status;
      Outcome.Said := Result.Report;
      Outcome.Writes := Host.Write_Count;
      if Result.Status = Landin.Driver.Status_Success then
         Outcome.Stack :=
           US.To_Unbounded_String (Host.Written ("stack.json"));
      end if;
      return Outcome;
   end Emit_Handler;

   Every_Backend : constant array (Positive range <>) of Target_Name :=
     [new String'("linux-x86-64"), new String'("linux-arm64"),
      new String'("linux-rv64"), new String'("darwin-arm64"),
      new String'("freebsd-x86-64"), new String'("freebsd-arm64"),
      new String'("cortex-m0")];

   --  What the margin pays before a handler on each of Every_Backend
   --  (D472's table), and the margin itself.
   Before_Handler : constant array (Every_Backend'Range) of Natural :=
     [152, 144, 144, 144, 152, 144, 188];
   Margin : constant array (Every_Backend'Range) of Natural :=
     [640, 640, 768, 640, 640, 640, 384];

   --  D474: a handler that records the kind and switches away fits the
   --  margin on every target, and with no handler the default report
   --  always does, D361's report or Cortex-M0's trap instruction: what
   --  the margin pays before the handler and the `trap` depth are no
   --  more than the margin.
   procedure A_Handler_That_Fits_Is_Emitted
     (Item : in out Landin.Testing.Context);

   procedure A_Handler_That_Fits_Is_Emitted
     (Item : in out Landin.Testing.Context)
   is
      procedure Fits (Index : Positive; Handler, What : String);

      procedure Fits (Index : Positive; Handler, What : String) is
         Target : constant String := Every_Backend (Index).all;
         Outcome : constant Handler_Outcome :=
           Emit_Handler (Handler_Program (Handler, True), Target);
         Text : constant String := US.To_String (Outcome.Stack);
         Trap : constant String :=
           (if Ada.Strings.Fixed.Index (Text, """trap"":") > 0
            then Text (Ada.Strings.Fixed.Index (Text, """trap"":")
                       .. Text'Last)
            else "");
      begin
         Landin.Testing.Check_Equal
           (Item, Outcome.Status, Landin.Driver.Status_Success,
            Target & ": " & What & " is emitted: "
            & US.To_String (Outcome.Said));
         Landin.Testing.Check_Equal
           (Item, Field (Text, "handler_entry_bytes"), Before_Handler (Index),
            Target & ": what the margin pays before a handler");
         Landin.Testing.Check_Equal
           (Item, Field (Text, "margin_bytes"), Margin (Index),
            Target & ": the margin");
         Landin.Testing.Check
           (Item, Field (Trap, "depth_bytes") >= 0
              and then Before_Handler (Index) + Field (Trap, "depth_bytes")
                <= Margin (Index),
            Target & ": " & What & " fits the margin: " & Trap);
      end Fits;
   begin
      for Index in Every_Backend'Range loop
         Fits (Index, Small_Handler, "a handler that switches away");
         Fits (Index, "", "the default report");
      end loop;
   end A_Handler_That_Fits_Is_Emitted;

   --  D474: a handler whose own frame is larger than the margin is
   --  refused on every target with the target's own figures, the
   --  handler's deepest path, and nothing written.
   procedure A_Handler_Past_The_Margin_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure A_Handler_Past_The_Margin_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Own : constant array (Every_Backend'Range) of Natural :=
        [1504, 1504, 1664, 1504, 1504, 1504, 1184];
   begin
      for Index in Every_Backend'Range loop
         declare
            Target : constant String := Every_Backend (Index).all;
            Outcome : constant Handler_Outcome :=
              Emit_Handler (Handler_Program (Large_Handler, True), Target);
            Said : constant String := US.To_String (Outcome.Said);
         begin
            Landin.Testing.Check_Equal
              (Item, Outcome.Status, Landin.Driver.Status_Reported,
               Target & ": a handler past the margin is refused: " & Said);
            Landin.Testing.Check
              (Item, Contains
                 (Said, "error[L0508]: the panic handler"
                  & " `main.panic_handler` needs"
                  & Natural'Image (Before_Handler (Index) + Own (Index))
                  & " bytes below a failed check, more than the"
                  & Natural'Image (Margin (Index))
                  & "-byte margin of a prepared stack on " & Target & ":"
                  & Natural'Image (Before_Handler (Index))
                  & " before it and" & Natural'Image (Own (Index))
                  & " for it, by main.panic_handler -> (trap) (D474)")
                 and then Contains (Said, "app/main.ldn:20:1"),
               Target & ": the refusal gives both numbers, the target and"
               & " the path, at the handler: " & Said);
            Landin.Testing.Check_Equal
              (Item, Outcome.Writes, 0,
               Target & ": a refused handler writes nothing");
         end;
      end loop;
   end A_Handler_Past_The_Margin_Is_Refused;

   --  D474: a handler whose calls reach an `any` call cannot be measured
   --  and is refused, naming the opening's kind and pointing at it.
   procedure An_Open_Handler_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure An_Open_Handler_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Index in Every_Backend'Range loop
         declare
            Target : constant String := Every_Backend (Index).all;
            Outcome : constant Handler_Outcome :=
              Emit_Handler (Handler_Program (Erased_Handler, True), Target);
            Said : constant String := US.To_String (Outcome.Said);
         begin
            Landin.Testing.Check_Equal
              (Item, Outcome.Status, Landin.Driver.Status_Reported,
               Target & ": an open handler is refused: " & Said);
            Landin.Testing.Check
              (Item, Contains
                 (Said, "error[L0508]: the panic handler"
                  & " `main.panic_handler` runs on the margin of a stack it"
                  & " overflowed," & Natural'Image (Margin (Index))
                  & " bytes on " & Target & ", and its depth cannot be"
                  & " known: its calls reach an opening of kind `any` in"
                  & " `main.erased` (D474)")
                 and then Contains (Said, "app/main.ldn:13:11"),
               Target & ": the refusal names the opening where it is: "
               & Said);
         end;
      end loop;
   end An_Open_Handler_Is_Refused;

   --  D474 applies only where a fibre can exist: without a
   --  `compiler.stack_prepare` the same large handler, and one that
   --  calls through `any`, are emitted on every target.
   procedure Without_A_Prepared_Stack_Any_Handler_Is_Emitted
     (Item : in out Landin.Testing.Context);

   procedure Without_A_Prepared_Stack_Any_Handler_Is_Emitted
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Index in Every_Backend'Range loop
         declare
            Target : constant String := Every_Backend (Index).all;
         begin
            Landin.Testing.Check_Equal
              (Item, Emit_Handler
                 (Handler_Program (Large_Handler, False), Target).Status,
               Landin.Driver.Status_Success,
               Target & ": a large handler with no prepared stack");
            Landin.Testing.Check_Equal
              (Item, Emit_Handler
                 (Handler_Program (Erased_Handler, False), Target).Status,
               Landin.Driver.Status_Success,
               Target & ": an open handler with no prepared stack");
         end;
      end loop;
   end Without_A_Prepared_Stack_Any_Handler_Is_Emitted;

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
      Landin.Testing.Register
        (Into, "stack report", "a handler that fits is emitted",
         A_Handler_That_Fits_Is_Emitted'Access);
      Landin.Testing.Register
        (Into, "stack report", "a handler past the margin is refused",
         A_Handler_Past_The_Margin_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "stack report", "an open handler is refused",
         An_Open_Handler_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "stack report",
         "without a prepared stack any handler is emitted",
         Without_A_Prepared_Stack_Any_Handler_Is_Emitted'Access);
   end Register;

end Landin.Tests.Stack_Report_Suite;
