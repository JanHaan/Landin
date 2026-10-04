--  Whether a compilation gives back what it took.
--
--  `refine` checks one program and exits, and for that nothing ever had to
--  be freed.  A process that checks the same program again on every edit
--  is the opposite case: whatever one compilation leaves allocated, the
--  next one leaves again, and memory grows with the number of edits rather
--  than with the program.  These cases run the whole driver in one process
--  over and over and require what the allocator holds afterwards to stay
--  where it was.
--
--  The measure is the allocator's count of bytes in use, not the resident
--  set.  The peak only rises, so it cannot see a leak at all; the current
--  resident set moves with whatever the kernel paged in and how the
--  allocator's free space fragmented.  Bytes in use depend only on which
--  allocations are still live, which for one deterministic request in a
--  process doing nothing else is the same number every time.  The first
--  few runs are not measured: the runtime's secondary stack and the
--  allocator's size-class caches grow once, to what one run needs, and
--  then stay there.
--
--  Deliberately uses the real host.  The measurement is the host
--  allocator's, and the program is read from the repository: the derived
--  log filter and the `core` it imports, nineteen sources, because a leak
--  that only a real program's tables make is not one a toy would show.
--  Nothing here runs in parallel with anything else that allocates.

with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces.C;
with System;

with Landin.Driver;
with Landin.Json;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Server.Documents;
with Landin.Server.Sessions;
with Landin.Server.Transport;
with Landin.Source;
with Landin.Stages;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Testing.Fakes;

package body Landin.Tests.Memory_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   --  Inside this host's own build tree, as every native case writes.
   Scratch : constant String :=
     "build/"
     & Ada.Environment_Variables.Value ("LANDIN_BUILD_TAG", "host")
     & "/"
     & Ada.Environment_Variables.Value ("LANDIN_BUILD_MODE", "debug")
     & "/test-scratch";

   Repository : constant String := "../..";

   Frontend   : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver   : aliased Landin.Stages.Resolution.Instance;
   Checker    : aliased Landin.Stages.Checking.Instance;
   Lowerer    : aliased Landin.Stages.Lowering.Instance;

   --  Allow bounded settling, but reject growth that continues across both
   --  parts of the measured tail.  A per-run leak can otherwise fit under
   --  the total allowance and pass forever.
   Tolerance : constant Long_Long_Integer := 64 * 1024;

   function Flat
     (Settled, Midpoint, Final : Long_Long_Integer) return Boolean is
     (Final - Settled <= Tolerance and then Final <= Midpoint);

   function Flat
     (Settled, Midpoint, Late, Final : Long_Long_Integer) return Boolean is
     (Final - Settled <= Tolerance
      and then not (Late > Midpoint and then Final > Late));

   --  Execute returns only after its per-run result has been finalized.
   --  Every sample, including the last, is taken at that same point.
   procedure Measure_Repeated
     (Meter     : Landin.Platform.Native.Native_Meter;
      Warm      : Positive;
      Measured  : Positive;
      Execute   : not null access function (Run : Positive) return Boolean;
      Settled   : out Long_Long_Integer;
      Midpoint  : out Long_Long_Integer;
      Late      : out Long_Long_Integer;
      Final     : out Long_Long_Integer;
      Completed : out Boolean);

   procedure Measure_Repeated
     (Meter     : Landin.Platform.Native.Native_Meter;
      Warm      : Positive;
      Measured  : Positive;
      Execute   : not null access function (Run : Positive) return Boolean;
      Settled   : out Long_Long_Integer;
      Midpoint  : out Long_Long_Integer;
      Late      : out Long_Long_Integer;
      Final     : out Long_Long_Integer;
      Completed : out Boolean) is
   begin
      pragma Assert (Measured >= 4);
      Settled := 0;
      Midpoint := 0;
      Late := 0;
      Final := 0;
      Completed := False;
      for Run in 1 .. Warm + Measured loop
         if not Execute (Run) then
            return;
         end if;
         Final := Meter.Sample.Allocated_Bytes;
         if Run = Warm then
            Settled := Final;
         elsif Run = Warm + Measured / 2 then
            Midpoint := Final;
         elsif Run = Warm + Measured / 2 + Measured / 4 then
            Late := Final;
         end if;
      end loop;
      Completed := True;
   end Measure_Repeated;

   procedure Gate_Rejects_Linear_Growth
     (Item : in out Landin.Testing.Context);

   procedure Gate_Rejects_Linear_Growth
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check
        (Item, Flat (0, 60 * 1024, 60 * 1024, 60 * 1024),
         "a bounded one-time allocation may settle");
      Landin.Testing.Check
        (Item, Flat (0, 0, 464, 464),
         "a late one-time allocation may settle");
      Landin.Testing.Check
        (Item, not Flat
           (0, 10 * 3 * 1024, 15 * 3 * 1024, 20 * 3 * 1024),
         "3 KiB per check is rejected within twenty checks");
      Landin.Testing.Check
        (Item, not Flat
           (0, 3 * 20 * 512, 4 * 20 * 512, 6 * 20 * 512),
         "512 bytes per edit is rejected within six sessions");
      Landin.Testing.Check
        (Item, not Flat (0, 70 * 1024, 70 * 1024, 70 * 1024),
         "the bound still rejects a large one-time allocation");
   end Gate_Rejects_Linear_Growth;

   procedure Gate_Sees_Retained_Run_Growth
     (Item : in out Landin.Testing.Context);

   procedure Gate_Sees_Retained_Run_Growth
     (Item : in out Landin.Testing.Context) is
      use type System.Address;
      function C_Malloc (Size : Interfaces.C.size_t) return System.Address
        with Import, Convention => C, External_Name => "malloc";
      procedure C_Free (Block : System.Address)
        with Import, Convention => C, External_Name => "free";
      --  mallinfo2 includes blocks in glibc's thread cache as allocated.
      --  Reusing those blocks is invisible to the meter until the cache
      --  empties. Seed that condition explicitly, then retain warm-up blocks
      --  until three successive allocations are visible. This control must
      --  work after other suites, not depend on being the first allocator.
      Block_Size : constant := 512;
      Seed_Count : constant := 8;
      Cache_Blocks : array (1 .. 128) of System.Address :=
        [others => System.Null_Address];
      Held : array (1 .. 8) of System.Address :=
        [others => System.Null_Address];
      Meter : Landin.Platform.Native.Native_Meter;
      Settled, Midpoint, Late, Final : Long_Long_Integer := 0;
      Completed : Boolean := False;
      Prepared : Boolean := False;
      Visible : Natural := 0;
      Earlier : Long_Long_Integer;

      function Retain_One (Run : Positive) return Boolean;

      function Retain_One (Run : Positive) return Boolean is
         Transient : Unbounded.Unbounded_String;
      begin
         if Run = 5 then
            Transient :=
              Unbounded.To_Unbounded_String (String'(1 .. 8 * 1024 => 't'));
         end if;
         Held (Run) := C_Malloc (Block_Size);
         return Held (Run) /= System.Null_Address
           and then (Run /= 5 or else Unbounded.Length (Transient) = 8 * 1024);
      end Retain_One;
   begin
      for Index in 1 .. Seed_Count loop
         Cache_Blocks (Index) := C_Malloc (Block_Size);
      end loop;
      for Index in 1 .. Seed_Count loop
         C_Free (Cache_Blocks (Index));
         Cache_Blocks (Index) := System.Null_Address;
      end loop;
      Earlier := Meter.Sample.Allocated_Bytes;
      for Index in Cache_Blocks'Range loop
         Cache_Blocks (Index) := C_Malloc (Block_Size);
         exit when Cache_Blocks (Index) = System.Null_Address;
         declare
            Current : constant Long_Long_Integer :=
              Meter.Sample.Allocated_Bytes;
         begin
            Visible := (if Current - Earlier >= Block_Size
                        then Visible + 1 else 0);
            Earlier := Current;
         end;
         if Visible = 3 then
            Prepared := True;
            exit;
         end if;
      end loop;
      if Prepared then
         Measure_Repeated
           (Meter, Warm => 2, Measured => 6, Execute => Retain_One'Access,
            Settled => Settled, Midpoint => Midpoint, Late => Late,
            Final => Final,
            Completed => Completed);
      end if;
      declare
         Small_Leak_Rejected : constant Boolean :=
           Prepared and then Completed
           and then Final - Settled in 1 .. Tolerance
           and then Late > Midpoint and then Final > Late
           and then not Flat (Settled, Midpoint, Late, Final);
      begin
         for Block of Cache_Blocks loop
            C_Free (Block);
         end loop;
         for Block of Held loop
            C_Free (Block);
         end loop;
         Landin.Testing.Check
           (Item, Small_Leak_Rejected,
            "post-run samples reject 512 retained bytes per run below 64 KiB"
            & " despite a finalized transient result"
            & "; allocator warmed " & Boolean'Image (Prepared)
            & "; total " & Long_Long_Integer'Image (Final - Settled)
            & ", tail parts " & Long_Long_Integer'Image (Late - Midpoint)
            & " and " & Long_Long_Integer'Image (Final - Late));
      end;
   end Gate_Sees_Retained_Run_Growth;

   function Image (Value : Long_Long_Integer) return String;

   function Image (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   function Request (Emitting : Boolean) return Landin.Platform.Path_List;

   function Request (Emitting : Boolean) return Landin.Platform.Path_List is
      Arguments : Landin.Platform.Path_List;
   begin
      Landin.Platform.Add (Arguments, "--target=linux-x86-64");
      Landin.Platform.Add (Arguments, "--root=" & Repository);
      if Emitting then
         Landin.Platform.Add (Arguments, "--emit=asm");
         Landin.Platform.Add (Arguments, "--debug=full");
         Landin.Platform.Add (Arguments, "--panic-map");
         Landin.Platform.Add
           (Arguments, "--build-report=" & Scratch & "/memory-report.json");
         Landin.Platform.Add (Arguments, "-o");
         Landin.Platform.Add (Arguments, Scratch & "/memory.s");
      end if;
      Landin.Platform.Add (Arguments, Repository & "/examples/derived_hosted");
      return Arguments;
   end Request;

   --  Runs the request Warm times unmeasured and Measured times more, and
   --  checks both the total growth and whether it persists across the tail.
   procedure Repeat
     (Item     : in out Landin.Testing.Context;
      Emitting : Boolean;
      Warm     : Positive;
      Measured : Positive;
      What     : String);

   procedure Repeat
     (Item     : in out Landin.Testing.Context;
      Emitting : Boolean;
      Warm     : Positive;
      Measured : Positive;
      What     : String)
   is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Tools : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Meter : Landin.Platform.Native.Native_Meter;
      Arguments : constant Landin.Platform.Path_List := Request (Emitting);
      Settled, Midpoint, Late, Final : Long_Long_Integer;
      Completed : Boolean;

      function Execute_One (Run : Positive) return Boolean;

      function Execute_One (Run : Positive) return Boolean is
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments, Host, Tools);
      begin
         if Result.Status /= Landin.Driver.Status_Success then
            Landin.Testing.Fail
              (Item, What & ": run" & Run'Image & " refused the program:"
               & Unbounded.To_String (Result.Report));
            return False;
         end if;
         return True;
      end Execute_One;
   begin
      Ada.Directories.Create_Path (Scratch);
      Measure_Repeated
        (Meter, Warm, Measured, Execute_One'Access,
         Settled, Midpoint, Late, Final, Completed);
      if not Completed then
         return;
      end if;
      Landin.Testing.Check
        (Item, Flat (Settled, Midpoint, Late, Final),
         What & ": after" & Measured'Image & " more runs the allocator "
         & "holds " & Image (Final - Settled) & " bytes more than after "
         & "the first" & Warm'Image & "; tail parts grew by "
         & Image (Late - Midpoint) & " and " & Image (Final - Late)
         & " bytes; at most " & Image (Tolerance)
         & " total and no sustained tail growth may remain");
   end Repeat;

   --  What an editor does on every keystroke: format the same file again.
   --  `--check` so nothing is written, whether a file is in the layout or
   --  not; every source of the derived log filter, laid out whole.
   procedure Formatting_Stays_Flat (Item : in out Landin.Testing.Context);

   procedure Formatting_Stays_Flat (Item : in out Landin.Testing.Context) is
      Host  : Landin.Platform.Native.Native_Filesystem;
      Tools : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Meter : Landin.Platform.Native.Native_Meter;
      Arguments : Landin.Platform.Path_List;
      Settled, Midpoint, Late, Final : Long_Long_Integer;
      Completed : Boolean;
      Warm : constant := 3;
      Measured : constant := 20;

      function Execute_One (Run : Positive) return Boolean;

      function Execute_One (Run : Positive) return Boolean is
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Arguments, Host, Tools);
      begin
         if Result.Status not in Landin.Driver.Status_Success
                               | Landin.Driver.Status_Reported
         then
            Landin.Testing.Fail
              (Item, "formatting run" & Run'Image & " was refused:"
               & Unbounded.To_String (Result.Report));
            return False;
         end if;
         return True;
      end Execute_One;
   begin
      Landin.Platform.Add (Arguments, "fmt");
      Landin.Platform.Add (Arguments, "--check");
      for Name of Landin.Platform.Path_List'
        (["app/app.ldn", "app/config.ldn", "app/dest.ldn", "app/entry.ldn",
          "app/filter.ldn", "app/reader.ldn", "main.ldn"])
      loop
         Landin.Platform.Add
           (Arguments, Repository & "/examples/derived_hosted/" & Name);
      end loop;
      Measure_Repeated
        (Meter, Warm, Measured, Execute_One'Access,
         Settled, Midpoint, Late, Final, Completed);
      if not Completed then
         return;
      end if;
      Landin.Testing.Check
        (Item, Flat (Settled, Midpoint, Late, Final),
         "formatting the derived log filter: after" & Measured'Image
         & " more runs the allocator holds " & Image (Final - Settled)
         & " bytes more; tail parts grew by " & Image (Late - Midpoint)
         & " and " & Image (Final - Late) & " bytes; at most "
         & Image (Tolerance) & " total and no sustained tail growth"
         & " may remain");
   end Formatting_Stays_Flat;

   procedure Checking_Stays_Flat (Item : in out Landin.Testing.Context);

   procedure Checking_Stays_Flat (Item : in out Landin.Testing.Context) is
   begin
      Repeat (Item, Emitting => False, Warm => 3, Measured => 20,
              What => "checking the derived log filter");
   end Checking_Stays_Flat;

   procedure Emission_Stays_Flat (Item : in out Landin.Testing.Context);

   procedure Emission_Stays_Flat (Item : in out Landin.Testing.Context) is
   begin
      Repeat (Item, Emitting => True, Warm => 2, Measured => 4,
              What => "emitting the derived log filter");
   end Emission_Stays_Flat;

   --  The control: the measure the two cases above rest on has to see a
   --  compilation that is kept, and one compilation has to be well past
   --  their tolerance, or a leak of whole compilations could pass them.
   --  One program lowered to verified IR is measured while it is alive
   --  and after it ends; then three are kept alive at once, and what the
   --  allocator holds has to grow by most of three of them.
   procedure A_Kept_Compilation_Is_Seen
     (Item : in out Landin.Testing.Context);

   procedure A_Kept_Compilation_Is_Seen
     (Item : in out Landin.Testing.Context)
   is
      type Kept is access Landin.Stages.Compilation;
      procedure Free is new Ada.Unchecked_Deallocation
        (Landin.Stages.Compilation, Kept);

      Host : Landin.Platform.Native.Native_Filesystem;
      Meter : Landin.Platform.Native.Native_Meter;
      Path : constant String :=
        "../tests/fixtures/positive/r491-contextual-statements/main.ldn";
      Text : Unbounded.Unbounded_String;
      Read : Landin.Platform.Read_Status;

      --  Every stage through lowering, which is what a check builds.
      procedure Lower (Work : in out Landin.Stages.Compilation);

      procedure Lower (Work : in out Landin.Stages.Compilation) is
         Order : Landin.Stages.Pipeline;
         Added : constant Landin.Source.Source_Id :=
           Landin.Stages.Add_Source
             (Work, Path, Unbounded.To_String (Text));
         Ran : Natural;
      begin
         pragma Assert (Landin.Source."/=" (Added, Landin.Source.No_Source));
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Resolver'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Landin.Stages.Append (Order, Lowerer'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check
           (Item, Ran = 5 and then not Landin.Stages.Failed (Work),
            "the control program reaches verified IR");
      end Lower;

      Volume : Long_Long_Integer;
   begin
      Host.Read_File (Path, Text, Read);
      Landin.Testing.Check
        (Item, Landin.Platform."=" (Read, Landin.Platform.Read_Ok),
         "the control program is read");

      --  Twice, so the second is measured after the allocator's caches
      --  have settled, as the flat cases measure.
      for Pass in 1 .. 2 loop
         declare
            Before : constant Long_Long_Integer :=
              Meter.Sample.Allocated_Bytes;
            Alive : Long_Long_Integer;
         begin
            declare
               Work : Landin.Stages.Compilation :=
                 Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            begin
               Lower (Work);
               Alive := Meter.Sample.Allocated_Bytes;
            end;
            Volume := Alive - Meter.Sample.Allocated_Bytes;
            if Pass = 2 then
               Landin.Testing.Check
                 (Item, Meter.Sample.Allocated_Bytes - Before <= Tolerance,
                  "a finished compilation leaves nothing behind");
            end if;
         end;
      end loop;

      Landin.Testing.Check
        (Item, Volume > 4 * Tolerance,
         "one compilation holds " & Image (Volume)
         & " bytes, far past the flat cases' tolerance");

      declare
         Before : constant Long_Long_Integer := Meter.Sample.Allocated_Bytes;
         Held : array (1 .. 3) of Kept;
      begin
         for Each of Held loop
            Each := new Landin.Stages.Compilation'
              (Landin.Stages.Create (Landin.Targets.Linux_X86_64));
            Lower (Each.all);
         end loop;
         Landin.Testing.Check
           (Item, Meter.Sample.Allocated_Bytes - Before >= 2 * Volume,
            "three kept compilations are counted: "
            & Image (Meter.Sample.Allocated_Bytes - Before) & " bytes");
         for Each of Held loop
            Free (Each);
         end loop;
      end;
   end A_Kept_Compilation_Is_Seen;

   --  A server session over the derived log filter: its entry module
   --  opened, twenty edits each analysed, a format, code actions and a
   --  close, against the real tree, which is this case's deliberate
   --  exception.  Whole sessions are repeated, so what one leaves behind
   --  -- a compilation, a document, a stand-in -- would show as growth.
   procedure Serving_Stays_Flat (Item : in out Landin.Testing.Context);

   procedure Serving_Stays_Flat (Item : in out Landin.Testing.Context) is
      Host     : aliased Landin.Platform.Native.Native_Filesystem;
      Meter    : Landin.Platform.Native.Native_Meter;
      Settled  : Long_Long_Integer := 0;
      Midpoint : Long_Long_Integer := 0;
      Warm     : constant := 2;
      Measured : constant := 6;
      Directory : constant String :=
        Ada.Directories.Full_Name (Repository & "/examples/derived_hosted");
      Root : constant String :=
        Ada.Directories.Full_Name (Repository);
      URI  : constant String :=
        Landin.Server.Documents.URI_Of (Directory & "/main.ldn");
      Text : Unbounded.Unbounded_String;
      Read : Landin.Platform.Read_Status;
      Script : Unbounded.Unbounded_String;

      procedure Send (Message : String);

      procedure Send (Message : String) is
      begin
         Unbounded.Append (Script, Landin.Server.Transport.Framed (Message));
      end Send;
   begin
      Host.Read_File (Directory & "/main.ldn", Text, Read);
      Send ("{""jsonrpc"":""2.0"",""id"":1,""method"":""initialize"","
            & """params"":{""capabilities"":{},""initializationOptions"":"
            & "{""roots"":[" & Landin.Json.Quoted
                (Landin.Server.Documents.URI_Of (Root)) & "]}}}");
      Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didOpen"","
            & """params"":{""textDocument"":{""uri"":"
            & Landin.Json.Quoted (URI) & ",""languageId"":""landin"","
            & """version"":1,""text"":"
            & Landin.Json.Quoted (Unbounded.To_String (Text)) & "}}}");
      for Edit in 2 .. 21 loop
         --  Every other edit breaks a body, so the stand-in is made too.
         Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didChange"","
               & """params"":{""textDocument"":{""uri"":"
               & Landin.Json.Quoted (URI) & ",""version"":"
               & Ada.Strings.Fixed.Trim (Edit'Image, Ada.Strings.Left)
               & "},""contentChanges"":[{""text"":"
               & Landin.Json.Quoted
                   (Unbounded.To_String (Text)
                    & (if Edit mod 2 = 0
                       then "broken: () -> none =" & ASCII.LF
                            & "    x := (" & ASCII.LF & "end broken"
                            & ASCII.LF
                       else ""))
               & "}]}}");
         Send ("{""jsonrpc"":""2.0"",""id"":" & Edit'Image
               & ",""method"":""textDocument/codeAction"",""params"":"
               & "{""textDocument"":{""uri"":" & Landin.Json.Quoted (URI)
               & "},""range"":{""start"":{""line"":0,""character"":0},"
               & """end"":{""line"":9999,""character"":0}},"
               & """context"":{""diagnostics"":[]}}}");
      end loop;
      Send ("{""jsonrpc"":""2.0"",""id"":90,""method"":"
            & """textDocument/formatting"",""params"":{""textDocument"":"
            & "{""uri"":" & Landin.Json.Quoted (URI) & "},""options"":"
            & "{""tabSize"":4,""insertSpaces"":true}}}");
      Send ("{""jsonrpc"":""2.0"",""method"":""textDocument/didClose"","
            & """params"":{""textDocument"":{""uri"":"
            & Landin.Json.Quoted (URI) & "}}}");
      Send ("{""jsonrpc"":""2.0"",""id"":91,""method"":""shutdown""}");
      Send ("{""jsonrpc"":""2.0"",""method"":""exit""}");

      for Run in 1 .. Warm + Measured loop
         declare
            Channel : Landin.Testing.Fakes.Fake_Channel;
            Status  : Landin.Server.Sessions.Exit_Status;
         begin
            Channel.Script_Unbounded (Script);
            Landin.Server.Sessions.Serve (Channel, Host'Access, Status);
            --  Twenty analyses published, so the work was done: the open and
            --  the first edit arrive together and are one.
            if Status /= 0
              or else Ada.Strings.Fixed.Index
                (Landin.Testing.Fakes.Output (Channel), "defect") > 0
              or else Ada.Strings.Fixed.Count
                (Landin.Testing.Fakes.Output (Channel),
                 """uri"":" & Landin.Json.Quoted (URI) & ",""version"":")
                < 20
              or else Ada.Strings.Fixed.Count
                (Landin.Testing.Fakes.Output (Channel), "L0102") < 10
            then
               Landin.Testing.Fail
                 (Item, "session" & Run'Image & " did not end cleanly:"
                  & Natural'Image (Ada.Strings.Fixed.Count
                      (Landin.Testing.Fakes.Output (Channel),
                       "publishDiagnostics"))
                  & " publications," & Natural'Image (Ada.Strings.Fixed.Count
                      (Landin.Testing.Fakes.Output (Channel), "L0102"))
                  & " syntax errors," & Natural'Image (Ada.Strings.Fixed.Count
                      (Landin.Testing.Fakes.Output (Channel),
                       """uri"":" & Landin.Json.Quoted (URI)
                       & ",""version"":")) & " of the entry; "
                  & Landin.Testing.Fakes.Logged (Channel));
               return;
            end if;
         end;
         if Run = Warm then
            Settled := Meter.Sample.Allocated_Bytes;
         elsif Run = Warm + Measured / 2 then
            Midpoint := Meter.Sample.Allocated_Bytes;
         end if;
      end loop;
      declare
         Final : constant Long_Long_Integer := Meter.Sample.Allocated_Bytes;
      begin
         Landin.Testing.Check
           (Item, Flat (Settled, Midpoint, Final),
            "serving the derived log filter: after" & Measured'Image
            & " more sessions of twenty edits the allocator holds "
            & Image (Final - Settled) & " bytes more; at most "
            & Image (Tolerance) & " total and "
            & Image (Final - Midpoint)
            & " in the last half; no tail growth may remain");
      end;
   end Serving_Stays_Flat;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "memory", "gate rejects linear growth",
         Gate_Rejects_Linear_Growth'Access);
      Landin.Testing.Register
        (Into, "memory", "a gate sees retained run growth",
         Gate_Sees_Retained_Run_Growth'Access);
      Landin.Testing.Register
        (Into, "memory", "checking stays flat",
         Checking_Stays_Flat'Access);
      Landin.Testing.Register
        (Into, "memory", "emission stays flat",
         Emission_Stays_Flat'Access);
      Landin.Testing.Register
        (Into, "memory", "a kept compilation is seen",
         A_Kept_Compilation_Is_Seen'Access);
      Landin.Testing.Register
        (Into, "memory", "formatting stays flat",
         Formatting_Stays_Flat'Access);
      Landin.Testing.Register
        (Into, "memory", "serving stays flat",
         Serving_Stays_Flat'Access);
   end Register;

end Landin.Tests.Memory_Suite;
