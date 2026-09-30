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
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Landin.Driver;
with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Source;
with Landin.Stages;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;

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

   --  Room for what cannot be the compilation's: the harness's own
   --  transcript grows by a line per check.  A compilation of this program
   --  holds megabytes, so a leak of even a small part of one per run is
   --  far past this after the measured runs.
   Tolerance : constant Long_Long_Integer := 64 * 1024;

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
   --  checks that the bytes in use after the last run are those after the
   --  last warm-up.
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
      Settled : Long_Long_Integer := 0;
      Accepted : Boolean := True;
   begin
      Ada.Directories.Create_Path (Scratch);
      for Run in 1 .. Warm + Measured loop
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Arguments, Host, Tools);
         begin
            if Result.Status /= Landin.Driver.Status_Success then
               Accepted := False;
               Landin.Testing.Fail
                 (Item, What & ": run" & Run'Image & " refused the program:"
                  & Unbounded.To_String (Result.Report));
               return;
            end if;
            if Run = Warm then
               Settled := Meter.Sample.Allocated_Bytes;
            end if;
         end;
      end loop;

      declare
         Final : constant Long_Long_Integer := Meter.Sample.Allocated_Bytes;
      begin
         Landin.Testing.Check
           (Item, Accepted and then Final - Settled <= Tolerance,
            What & ": after" & Measured'Image & " more runs the allocator "
            & "holds " & Image (Final - Settled) & " bytes more than after "
            & "the first" & Warm'Image & "; at most " & Image (Tolerance)
            & " may remain");
      end;
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
      Settled : Long_Long_Integer := 0;
      Warm : constant := 3;
      Measured : constant := 20;
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
      for Run in 1 .. Warm + Measured loop
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Arguments, Host, Tools);
         begin
            if Result.Status not in Landin.Driver.Status_Success
                                  | Landin.Driver.Status_Reported
            then
               Landin.Testing.Fail
                 (Item, "formatting run" & Run'Image & " was refused:"
                  & Unbounded.To_String (Result.Report));
               return;
            end if;
            if Run = Warm then
               Settled := Meter.Sample.Allocated_Bytes;
            end if;
         end;
      end loop;
      declare
         Final : constant Long_Long_Integer := Meter.Sample.Allocated_Bytes;
      begin
         Landin.Testing.Check
           (Item, Final - Settled <= Tolerance,
            "formatting the derived log filter: after" & Measured'Image
            & " more runs the allocator holds " & Image (Final - Settled)
            & " bytes more; at most " & Image (Tolerance) & " may remain");
      end;
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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
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
   end Register;

end Landin.Tests.Memory_Suite;
