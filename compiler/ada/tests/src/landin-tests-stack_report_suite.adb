with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Backend.Dispatch;
with Landin.Driver;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Targets;
with Landin.Testing.Fakes;

--  D447's stack-depth report (D467, D468), through the driver on a fake
--  host: the frames and depths of a closed graph on every native target,
--  what a switch and a failed check cost, each kind of opening named where
--  it is, the same bytes for the same program, and the refusals.
package body Landin.Tests.Stack_Report_Suite is

   package US renames Ada.Strings.Unbounded;
   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;

   LF : constant Character := Character'Val (10);

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   type Target_Name is access constant String;
   Native : constant array (Positive range <>) of Target_Name :=
     [new String'("linux-x86-64"), new String'("linux-arm64"),
      new String'("linux-rv64"), new String'("cortex-m0")];
   Profiles : constant array (Positive range <>) of Target_Name :=
     [new String'("none"), new String'("size"), new String'("speed")];

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

   Counted_Program : constant String :=
     "leaf: (x: u32) -> (y: u32) =" & LF
     & "    y = x" & LF
     & "end leaf" & LF
     & LF
     & "apply: (f: (x: u32) -> (y: u32), x: u32) -> (y: u32) =" & LF
     & "    y = f(x)" & LF
     & "end apply" & LF
     & LF
     & "public main: () -> (code: i32) =" & LF
     & "    _ = apply(leaf, 7)" & LF
     & "    code = 0" & LF
     & "end main" & LF;

   --  Every backend fills every counter of the build report, and its
   --  stack is the frame the depth report gives the same routine: here a
   --  leaf, a routine calling through a function value, and main calling
   --  it, each at the reference profile, which keeps every value in the
   --  frame.
   procedure The_Build_Report_Counts_On_Every_Target
     (Item : in out Landin.Testing.Context);

   procedure The_Build_Report_Counts_On_Every_Target
     (Item : in out Landin.Testing.Context)
   is
      --  The line of Text that begins with Prefix, or "".
      function Line_Of (Text, Prefix : String) return String;
      function Line_Of (Text, Prefix : String) return String is
         First : constant Natural := Ada.Strings.Fixed.Index
           (Text, LF & Prefix);
         Last : Natural;
      begin
         if First = 0 then
            return "";
         end if;
         Last := First + 1;
         while Last < Text'Last and then Text (Last + 1) /= LF loop
            Last := Last + 1;
         end loop;
         return Text (First + 1 .. Last);
      end Line_Of;
   begin
      for Index in Native'Range loop
         declare
            Target : constant String := Native (Index).all;
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Result : Landin.Driver.Outcome;
         begin
            Host.Add_File ("main.ldn", Counted_Program);
            Args.Append ("--target=" & Target);
            if Target /= "cortex-m0" then
               Args.Append ("--link=libc");
            end if;
            Args.Append ("--optimize=none");
            Args.Append ("--specialize=off");
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("out.s");
            Args.Append ("--build-report=build.json");
            Args.Append ("--stack-report=stack.json");
            Args.Append ("main.ldn");
            Result := Landin.Driver.Execute (Args, Host, Tools);
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               Target & " emits with both reports: "
               & US.To_String (Result.Report));
            declare
               Build : constant String := Host.Written ("build.json");
               Stack : constant String := Host.Written ("stack.json");
               function Number (Routine : Positive) return String is
                 (Ada.Strings.Fixed.Trim
                    (Routine'Image, Ada.Strings.Both));
               function Counted (Routine : Positive) return String is
                 (Line_Of (Build, "{""item"":" & Number (Routine) & ","));
               function Measured (Routine : Positive) return String is
                 (Line_Of (Stack, "{""item"":" & Number (Routine) & ","));
               Leaf : constant String := Counted (1);
               Apply : constant String := Counted (2);
               Main : constant String := Counted (3);
            begin
               for Routine in 1 .. 3 loop
                  Landin.Testing.Check
                    (Item, Field (Counted (Routine), "stack_bytes") > 0
                       and then Field (Counted (Routine), "stack_bytes")
                         = Field (Measured (Routine), "frame_bytes")
                       and then Field (Counted (Routine), "stack_bytes")
                         > Field (Counted (Routine), "frame_bytes")
                       and then Field (Counted (Routine), "frame_bytes") > 0,
                     Target & ": a routine's stack is its depth report "
                     & "frame and more than its frame: "
                     & Counted (Routine) & " " & Measured (Routine));
                  Landin.Testing.Check
                    (Item, Field (Counted (Routine), "instructions") > 0
                       and then Field (Counted (Routine), "stack_loads") > 0
                       and then Field (Counted (Routine), "stack_stores") > 0
                       and then Field (Counted (Routine), "spill_count") > 0
                       and then Field (Counted (Routine), "register_count")
                         = 0,
                     Target & ": the reference profile's sites are counted "
                     & "and it holds no value in a register: "
                     & Counted (Routine));
               end loop;
               Landin.Testing.Check
                 (Item, Field (Leaf, "direct_calls") = 0
                    and then Field (Leaf, "indirect_calls") = 0
                    and then Field (Apply, "direct_calls") = 0
                    and then Field (Apply, "indirect_calls") = 1
                    and then Field (Main, "direct_calls") = 1
                    and then Field (Main, "indirect_calls") = 0,
                  Target & ": each call is counted as it is made: "
                  & Build);
            end;
         end;
      end loop;
   end The_Build_Report_Counts_On_Every_Target;

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
      --  D620: a Cortex-M description with a float unit saves d8-d15 and
      --  FPSCR too, and its margin pays for the extended exception frame
      --  and that larger switch.
      declare
         use type Landin.Targets.Byte_Count;
         Float : constant Landin.Backend.Dispatch.Stack_Facts :=
           Landin.Backend.Dispatch.Stack_Facts_Of
             (Landin.Targets.Cortex_M, Float => True);
      begin
         Landin.Testing.Check
           (Item, Float.Switch_Bytes = 120 and then Float.Prepared_Bytes = 120
              and then Float.Limit_Margin = 528
              and then Float.Unchecked = 64
              and then Float.Handler_Entry = 260,
            "a float unit's switch, first frame, margin and handler entry");
      end;
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
   --  a call through its table, which D570 closes as it closes a call
   --  through `any` or a function value.
   procedure Each_Opening_Is_Named
     (Item : in out Landin.Testing.Context);

   procedure Each_Opening_Is_Named
     (Item : in out Landin.Testing.Context)
   is
      type Wanted is record
         Caller, Callee : Target_Name;
      end record;
      type Wanted_List is array (Positive range <>) of Wanted;
      Closures : constant Wanted_List :=
        [(new String'("main.apply"), new String'("main.identity")),
         (new String'("main.erased"), new String'("main.tally_total")),
         (new String'("main.through"), new String'("main.tally_total"))];
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
      Opened ("recursion", "main.down", """line"":32,""column"":9",
              "main.down");
      Opened ("assembly", "main.pushing", """line"":36,""column"":5");
      Opened ("foreign", "main.main", """line"":52,""column"":9",
              "main.labs");
      Landin.Testing.Check
        (Item, Contains (Main, """closed"":false")
           and then Contains (Main, """openings"":[1,2,3]"),
         "main reaches every opening: " & Main);
      --  D570: a call through a function value, `any` or a generic's
      --  table reaches what the program holds that it can be, and is
      --  closed by them.
      for Closed of Closures loop
         Landin.Testing.Check
           (Item, Contains
              (Row (Text, Closed.Caller.all), """closed"":true")
              and then Contains
                (Row (Text, Closed.Caller.all),
                 """path"":[""" & Closed.Caller.all & ""","""
                 & Closed.Callee.all & """]")
              and then Field (Row (Text, Closed.Caller.all), "depth_bytes")
                = Field (Row (Text, Closed.Caller.all), "frame_bytes")
                  + Field (Row (Text, Closed.Callee.all), "depth_bytes"),
            Closed.Caller.all & " is closed through "
            & Closed.Callee.all & ": " & Text);
      end loop;
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
        (Item, Contains (Refusal (Unemitted), "--stack-report describes"
           & " emitted machine code: add --emit=asm or --emit=exe"),
         "a check has no frames to report");
      As_IR.Append ("--emit=ir");
      As_IR.Append ("--stack-report=stack.json");
      Landin.Testing.Check
        (Item, Contains (Refusal (As_IR), "--stack-report describes machine"
                         & " code, and --emit=ir"),
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

   --  A call through `any` is closed by the concept's tables (D570); a
   --  recursion is open whatever the program holds.
   Erased_Handler : constant String :=
     "    seen = i32(erased(any(addr held)))" & LF
     & "    _ = kind" & LF
     & "    _ = site" & LF;

   Recursive_Handler : constant String :=
     "    seen = i32(down(3))" & LF
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
       & "end main" & LF
       & "down: (n: u32) -> (y: u32) =" & LF
       & "    y = 0" & LF
       & "    return when n == 0" & LF
       & "    y = down(n - 1)" & LF
       & "end down" & LF);

   type Handler_Outcome is record
      Status : Natural := 0;
      Said : US.Unbounded_String;
      Stack : US.Unbounded_String;
      Assembly : US.Unbounded_String;
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
         Outcome.Assembly :=
           US.To_Unbounded_String (Host.Written ("out.s"));
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
              Emit_Handler (Handler_Program (Recursive_Handler, True), Target);
            Said : constant String := US.To_String (Outcome.Said);
            Erased : constant Handler_Outcome :=
              Emit_Handler (Handler_Program (Erased_Handler, True), Target);
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
                  & " known: its calls reach an opening of kind `recursion`"
                  & " in `main.down` calling `main.down` (D474)")
                 and then Contains (Said, "y = down(n - 1)"),
               Target & ": the refusal names the opening where it is: "
               & Said);
            --  D570: the same handler through `any` reaches only the
            --  concept's one provider, so its depth is known and judged.
            Landin.Testing.Check
              (Item, not Contains
                 (US.To_String (Erased.Said), "its depth cannot be known"),
               Target & ": a call through `any` is closed by its concept's"
               & " tables: " & US.To_String (Erased.Said));
            --  Where the provider's depth fits the margin, the handler
            --  through `any` is emitted.
            if Target in "linux-x86-64" | "linux-arm64" then
               Landin.Testing.Check_Equal
                 (Item, Erased.Status, Landin.Driver.Status_Success,
                  Target & ": a handler through `any` that fits is emitted: "
                  & US.To_String (Erased.Said));
            end if;
         end;
      end loop;
   end An_Open_Handler_Is_Refused;

   --  D570: a fibre's entry that calls through `any` is closed on every
   --  target, by the concept's one provider, so its stack is sized from
   --  the number the report gives.
   procedure A_Fibre_Entry_Through_Any_Is_Closed
     (Item : in out Landin.Testing.Context);

   procedure A_Fibre_Entry_Through_Any_Is_Closed
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Index in Every_Backend'Range loop
         declare
            Target : constant String := Every_Backend (Index).all;
            Text : constant String := US.To_String
              (Emit_Handler
                 (Handler_Program (Small_Handler, True), Target).Stack);
            Entry_Row : constant String := Row (Text, "main.fibre");
            Erased : constant String := Row (Text, "main.erased");
         begin
            Landin.Testing.Check
              (Item, Contains (Entry_Row, """closed"":true")
                 and then Contains (Erased, """closed"":true")
                 and then Field (Erased, "depth_bytes")
                   >= Field (Erased, "frame_bytes")
                      + Field (Row (Text, "main.tally_total"), "depth_bytes"),
               Target & ": a fibre's entry through `any` is closed: "
               & Entry_Row & " " & Erased);
            Landin.Testing.Check
              (Item, Field (Entry_Row, "depth_bytes")
                 >= Field (Entry_Row, "frame_bytes")
                    + Field (Erased, "depth_bytes"),
               Target & ": the entry's depth counts its provider's: "
               & Entry_Row);
         end;
      end loop;
   end A_Fibre_Entry_Through_Any_Is_Closed;

   --  The library's own round of turns (D571): two tasks over a spinning
   --  round, written against `core` alone so that every target emits it.
   Round_Program : constant String :=
     "import core/failure" & LF
     & "import core/fibre" & LF
     & "import core/fibre/stacks" & LF
     & "mut steps: u32 = 0" & LF
     & "turning: type = struct" & LF
     & "    runs: any fibre.turns" & LF
     & "end turning" & LF
     & "twice: (inout state: turning) -> none ! failure.reason =" & LF
     & "    steps += 1" & LF
     & "    state.runs.yield()" & LF
     & "    steps += 1" & LF
     & "end twice" & LF
     & "both: (runs: any fibre.turns) -> none ! failure.reason =" & LF
     & "    mut backing: [2 * 2048]u8 = zeroed" & LF
     & "    mut tasks := try fibre.turns_over(runs, backing, 2)" & LF
     & "    defer fibre.join(tasks) else none" & LF
     & "    one: turning = (runs: runs)" & LF
     & "    try fibre.admit(tasks, twice, one)" & LF
     & "    try fibre.admit(tasks, twice, one)" & LF
     & "    try fibre.join(tasks)" & LF
     & "end both" & LF
     & "public main: () -> (code: i32) =" & LF
     & "    code = 1" & LF
     & "    mut state: stacks.round_space = zeroed" & LF
     & "    mut entries: [3]usize = zeroed" & LF
     & "    idler: stacks.spin = zeroed" & LF
     & "    round := stacks.round_over(state, entries, any(addr idler))"
     & " else (problem)" & LF
     & "        _ = problem" & LF
     & "        return" & LF
     & "    end" & LF
     & "    both(any(addr round)) else (problem)" & LF
     & "        _ = problem" & LF
     & "        return" & LF
     & "    end" & LF
     & "    code = i32(steps)" & LF
     & "end main" & LF;

   --  D571: beneath the round's yield only its sweep, which calls nothing,
   --  the idler and the switch take the yielding fibre's stack, and the
   --  yield goes no more than D465's 1 KiB deeper than its switch, on
   --  every target at every profile; the round's wait goes no deeper than
   --  through its yield.  The checkout's
   --  `core` is read from the real host deliberately, from the test
   --  program's working directory, compiler/ada, into the fake host's
   --  library, so that the round measured is the library's own.
   procedure A_Round_Yields_At_Its_Switch
     (Item : in out Landin.Testing.Context);

   procedure A_Round_Yields_At_Its_Switch
     (Item : in out Landin.Testing.Context)
   is
      Real : Landin.Platform.Native.Native_Filesystem;
      Library : constant String := "/opt/landin/lib/landin";

      procedure Copy
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem;
         From, To : String);

      procedure Copy
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem;
         From, To : String)
      is
         Entries : Landin.Platform.Path_List;
         Listed : Landin.Platform.List_Status;
      begin
         Real.List_Directory (From, Entries, Listed);
         if Listed /= Landin.Platform.List_Ok then
            raise Program_Error with "the checkout's " & From
              & " cannot be listed";
         end if;
         Host.Add_Directory (To);
         for Name of Entries loop
            if Real.Is_Directory (From & "/" & Name) then
               Copy (Host, From & "/" & Name, To & "/" & Name);
            elsif Name'Length > 4
              and then Name (Name'Last - 3 .. Name'Last) = ".ldn"
            then
               declare
                  Text : US.Unbounded_String;
                  Status : Landin.Platform.Read_Status;
               begin
                  Real.Read_File (From & "/" & Name, Text, Status);
                  if Status /= Landin.Platform.Read_Ok then
                     raise Program_Error with "the checkout's " & From
                       & "/" & Name & " cannot be read";
                  end if;
                  Host.Add_File (To & "/" & Name, US.To_String (Text));
               end;
            end if;
         end loop;
      end Copy;
   begin
      for Target of Native loop
         for Optimize of Profiles loop
            declare
               Host : Landin.Testing.Fakes.Fake_Filesystem;
               Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
               Args : Landin.Platform.Path_List;
               Result : Landin.Driver.Outcome;
               What : constant String := Target.all & " at " & Optimize.all;
            begin
               Host.Set_Executable_Directory ("/opt/landin/bin");
               Host.Add_Directory ("/opt/landin");
               Host.Add_Directory ("/opt/landin/lib");
               Host.Add_Directory (Library);
               Copy (Host, "../../core", Library & "/core");
               Host.Add_File ("main.ldn", Round_Program);
               Args.Append ("--target=" & Target.all);
               if Target.all /= "cortex-m0" then
                  Args.Append ("--link=libc");
               end if;
               Args.Append ("--optimize=" & Optimize.all);
               Args.Append ("--emit=asm");
               Args.Append ("-o");
               Args.Append ("out.s");
               Args.Append ("--stack-report=stack.json");
               Args.Append ("main.ldn");
               Result := Landin.Driver.Execute (Args, Host, Tools);
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Success,
                  What & ": the round emits: "
                  & US.To_String (Result.Report));
               declare
                  Text : constant String := Host.Written ("stack.json");
                  Yield : constant String :=
                    Row (Text, "core.fibre.stacks.round_yield");
                  Sweep : constant String :=
                    Row (Text, "core.fibre.stacks.sweep");
                  Wait : constant String :=
                    Row (Text, "core.fibre.stacks.round_wait");
                  Below_Switch : constant Integer :=
                    Field (Yield, "depth_bytes")
                    - Field (Yield, "frame_bytes")
                    - Field (Text, "switch_bytes");
               begin
                  Landin.Testing.Check
                    (Item, Contains (Yield, """closed"":true")
                       and then
                         (Contains
                            (Yield, """path"":[""core.fibre.stacks."
                             & "round_yield"",""(switch)""]")
                          or else Contains
                            (Yield, """path"":[""core.fibre.stacks."
                             & "round_yield"",""core.fibre.stacks.sweep"""))
                       and then
                         (Contains
                            (Sweep, """path"":[""core.fibre.stacks.sweep""]")
                          or else Contains
                            (Sweep, """path"":[""core.fibre.stacks.sweep"","
                             & """(trap)""]")),
                     What & ": beneath the yield only its sweep, which calls"
                     & " nothing, and its switch: " & Yield & " " & Sweep);
                  Landin.Testing.Check
                    (Item, Below_Switch in 0 .. 1024,
                     What & ": the yield goes" & Below_Switch'Image
                     & " bytes deeper than its switch, within 1 KiB");
                  Landin.Testing.Check
                    (Item, Contains
                       (Wait, """path"":[""core.fibre.stacks.round_wait"","
                        & """core.fibre.stacks.round_yield"""),
                     What & ": the wait goes no deeper than its yield: "
                     & Wait);
               end;
            end;
         end loop;
      end loop;
   end A_Round_Yields_At_Its_Switch;

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
                 (Handler_Program (Recursive_Handler, False), Target).Status,
               Landin.Driver.Status_Success,
               Target & ": an open handler with no prepared stack");
         end;
      end loop;
   end Without_A_Prepared_Stack_Any_Handler_Is_Emitted;

   --  D491: off Linux, the default report of a program that prepares a
   --  stack moves to a stack of its own before it calls the C library's
   --  `write`, so the stack that failed pays only the report's frame and
   --  the trap's depth is closed; with no prepared stack the report stays
   --  on the stack it was called on, its depth open, and Linux's system
   --  call needs no stack, so its assembly has none.  Off Linux it first
   --  claims the latch every thread's report shares (D498).
   procedure The_Default_Report_Writes_On_Its_Own_Stack
     (Item : in out Landin.Testing.Context);

   procedure The_Default_Report_Writes_On_Its_Own_Stack
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Index in Every_Backend'Range loop
         declare
            Target : constant String := Every_Backend (Index).all;
            Foreign : constant Boolean :=
              Target in "darwin-arm64" | "freebsd-x86-64" | "freebsd-arm64";
            Call : constant String :=
              (if Target = "darwin-arm64" then "bl _write"
               elsif Target = "freebsd-x86-64" then "call write"
               else "bl write");
         begin
            for Prepares in Boolean loop
               declare
                  Outcome : constant Handler_Outcome :=
                    Emit_Handler (Handler_Program ("", Prepares), Target);
                  Text : constant String := US.To_String (Outcome.Assembly);
                  Stack : constant String := US.To_String (Outcome.Stack);
                  Moved : constant Natural :=
                    Ada.Strings.Fixed.Index (Text, "landin_report_stack");
                  --  The first call of `write` after the move: Darwin's
                  --  key-making initializer calls it too, before (D506).
                  Called : constant Natural :=
                    (if Moved = 0 then 0
                     else Ada.Strings.Fixed.Index (Text, Call, Moved));
                  --  D498: the latch the report claims before it moves.
                  Latched : constant Natural :=
                    Ada.Strings.Fixed.Index (Text, "landin_report_latch");
                  What : constant String :=
                    Target & (if Prepares then " with" else " without")
                    & " a prepared stack";
               begin
                  Landin.Testing.Check_Equal
                    (Item, Outcome.Status, Landin.Driver.Status_Success,
                     What & " is emitted: " & US.To_String (Outcome.Said));
                  if Foreign and then Prepares then
                     Landin.Testing.Check
                       (Item, Moved > 0 and then Called > Moved,
                        What & ": the report moves to its own stack before"
                        & " it calls write");
                     Landin.Testing.Check
                       (Item, Latched > 0 and then Latched < Moved,
                        What & ": the report claims its latch before it"
                        & " moves");
                     Landin.Testing.Check
                       (Item, Contains (Stack, """closed"":true,"
                          & """foreign_write"":true"),
                        What & ": the trap's depth is closed: " & Stack);
                  else
                     Landin.Testing.Check
                       (Item, Moved = 0,
                        What & ": the report keeps the stack it is on");
                     Landin.Testing.Check
                       (Item, Latched = 0,
                        What & ": the report claims no latch");
                  end if;
                  if Foreign and then not Prepares then
                     Landin.Testing.Check
                       (Item, Contains (Stack, """closed"":false,"
                          & """foreign_write"":true"),
                        What & ": the trap's depth is open: " & Stack);
                  end if;
               end;
            end loop;
         end;
      end loop;
   end The_Default_Report_Writes_On_Its_Own_Stack;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "stack report", "a closed graph on every target",
         A_Closed_Graph_On_Every_Target'Access);
      Landin.Testing.Register
        (Into, "stack report", "the build report counts on every target",
         The_Build_Report_Counts_On_Every_Target'Access);
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
        (Into, "stack report", "a yield goes little deeper than its switch",
         A_Round_Yields_At_Its_Switch'Access);
      Landin.Testing.Register
        (Into, "stack report", "a fibre's entry through any is closed",
         A_Fibre_Entry_Through_Any_Is_Closed'Access);
      Landin.Testing.Register
        (Into, "stack report",
         "without a prepared stack any handler is emitted",
         Without_A_Prepared_Stack_Any_Handler_Is_Emitted'Access);
      Landin.Testing.Register
        (Into, "stack report",
         "the default report writes on its own stack",
         The_Default_Report_Writes_On_Its_Own_Stack'Access);
   end Register;

end Landin.Tests.Stack_Report_Suite;
