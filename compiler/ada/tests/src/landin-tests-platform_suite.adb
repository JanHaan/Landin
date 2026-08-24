with Ada.Directories;
with Ada.Strings.Unbounded;

with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Testing.Fakes;

package body Landin.Tests.Platform_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Platform.Capture_Mode;
   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;

   Scratch : constant String := "build/test-scratch";

   procedure Fake_Reads_Report_Their_Reason
     (Item : in out Landin.Testing.Context);

   procedure Fake_Reads_Report_Their_Reason
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Testing.Fakes.Fake_Filesystem;
      Content : Unbounded.Unbounded_String;
      Status  : Landin.Platform.Read_Status;
   begin
      Host.Add_File ("a/one.ldn", "content");
      Host.Add_Directory ("a");
      Host.Add_Unreadable ("a/locked.ldn");

      Host.Read_File ("a/one.ldn", Content, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Read_Ok, "a present file reads");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Content), "content",
         "content round trips");

      Host.Read_File ("a/missing.ldn", Content, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Not_Found,
         "a missing file is not found rather than an exception");

      Host.Read_File ("a/locked.ldn", Content, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Not_Readable,
         "an unreadable file says so");

      Host.Read_File ("a", Content, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Not_Readable,
         "a directory is not readable as a file");
   end Fake_Reads_Report_Their_Reason;

   procedure Fake_Listings_Are_Sorted_And_Shallow
     (Item : in out Landin.Testing.Context);

   procedure Fake_Listings_Are_Sorted_And_Shallow
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Testing.Fakes.Fake_Filesystem;
      Entries : Landin.Platform.Path_List;
      Status  : Landin.Platform.List_Status;
   begin
      Host.Add_Directory ("root");
      Host.Add_File ("root/zebra.ldn", "");
      Host.Add_File ("root/apple.ldn", "");
      Host.Add_Directory ("root/nested");
      Host.Add_File ("root/nested/deep.ldn", "");

      Host.List_Directory ("root", Entries, Status);

      Landin.Testing.Check
        (Item, Status = Landin.Platform.List_Ok, "the directory listed");
      Landin.Testing.Check_Equal
        (Item, Natural (Entries.Length), 3, "only immediate children");
      Landin.Testing.Check_Equal
        (Item, Entries.Element (1), "apple.ldn", "sorted first");
      Landin.Testing.Check_Equal
        (Item, Entries.Element (2), "nested", "sorted second");
      Landin.Testing.Check_Equal
        (Item, Entries.Element (3), "zebra.ldn", "sorted third");

      Host.List_Directory ("root/apple.ldn", Entries, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Not_A_Directory,
         "a file is not a directory");

      Host.List_Directory ("nowhere", Entries, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Directory_Not_Found,
         "a missing directory says so");
   end Fake_Listings_Are_Sorted_And_Shallow;

   procedure Fake_Tools_Record_Their_Command
     (Item : in out Landin.Testing.Context);

   procedure Fake_Tools_Record_Their_Command
     (Item : in out Landin.Testing.Context)
   is
      Runner    : Landin.Testing.Fakes.Fake_Tool_Runner;
      Arguments : Landin.Platform.Path_List;
      Result    : Landin.Platform.Tool_Result;
   begin
      Runner.Set_Result (3, "assembler: no such instruction");
      Landin.Platform.Add (Arguments, "-o");
      Landin.Platform.Add (Arguments, "out.o");

      Runner.Run ("as", Arguments, Result);

      Landin.Testing.Check_Equal
        (Item, Runner.Last_Command, "as -o out.o",
         "the tool call is recorded rather than run");
      Landin.Testing.Check_Equal
        (Item, Result.Exit_Code, 3, "a failing tool reports its status");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Result.Output),
         "assembler: no such instruction", "tool output is captured");
      Landin.Testing.Check_Equal
        (Item, Runner.Run_Count, 1, "the tool ran once");
   end Fake_Tools_Record_Their_Command;

   procedure Set_Result_Remains_Sticky
     (Item : in out Landin.Testing.Context);

   procedure Set_Result_Remains_Sticky
     (Item : in out Landin.Testing.Context)
   is
      Runner    : Landin.Testing.Fakes.Fake_Tool_Runner;
      Arguments : Landin.Platform.Path_List;
      First     : Landin.Platform.Tool_Result;
      Second    : Landin.Platform.Tool_Result;
   begin
      Runner.Set_Result (7, "same result");
      Runner.Run ("first", Landin.Platform.No_Arguments, First);
      Landin.Platform.Add (Arguments, "argument");
      Runner.Run
        ("second", Arguments, Second, Landin.Platform.Output_Only);

      Landin.Testing.Check_Equal
        (Item, First.Exit_Code, 7, "the first sticky status is returned");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (First.Output), "same result",
         "the first sticky output is returned");
      Landin.Testing.Check_Equal
        (Item, Second.Exit_Code, 7, "the second sticky status is returned");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Second.Output), "same result",
         "the second sticky output is returned");
      Landin.Testing.Check_Equal
        (Item, Runner.Run_Count, 2, "both sticky calls are recorded");
      Landin.Testing.Check_Equal
        (Item, Runner.Last_Command, "second argument",
         "the last command projects the second call");
      Landin.Testing.Check
        (Item, Runner.Last_Capture = Landin.Platform.Output_Only,
         "the last capture projects the second call");
   end Set_Result_Remains_Sticky;

   procedure Fake_Tools_Return_Scripted_Results_In_Order
     (Item : in out Landin.Testing.Context);

   procedure Fake_Tools_Return_Scripted_Results_In_Order
     (Item : in out Landin.Testing.Context)
   is
      Runner    : Landin.Testing.Fakes.Fake_Tool_Runner;
      As_Result : Landin.Platform.Tool_Result;
      Ld_Result : Landin.Platform.Tool_Result;
   begin
      Runner.Add_Result (0, "assembled");
      Runner.Add_Result (1, "undefined symbol");

      Runner.Run ("as", Landin.Platform.No_Arguments, As_Result);
      Runner.Run ("ld", Landin.Platform.No_Arguments, Ld_Result);

      Landin.Testing.Check_Equal
        (Item, As_Result.Exit_Code, 0, "the assembler result comes first");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (As_Result.Output), "assembled",
         "the assembler output comes first");
      Landin.Testing.Check_Equal
        (Item, Ld_Result.Exit_Code, 1, "the linker result comes second");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Ld_Result.Output), "undefined symbol",
         "the linker output comes second");
   end Fake_Tools_Return_Scripted_Results_In_Order;

   procedure Fake_Tools_Record_Every_Call
     (Item : in out Landin.Testing.Context);

   procedure Fake_Tools_Record_Every_Call
     (Item : in out Landin.Testing.Context)
   is
      Runner     : Landin.Testing.Fakes.Fake_Tool_Runner;
      As_Args    : Landin.Platform.Path_List;
      Ld_Args    : Landin.Platform.Path_List;
      Result     : Landin.Platform.Tool_Result;
   begin
      Runner.Set_Result (0, "");
      Landin.Platform.Add (As_Args, "source with spaces.s");
      Landin.Platform.Add (As_Args, "-o");
      Landin.Platform.Add (As_Args, "out.o");
      Landin.Platform.Add (Ld_Args, "out.o");
      Landin.Platform.Add (Ld_Args, "-o");
      Landin.Platform.Add (Ld_Args, "program");

      Runner.Run
        ("as", As_Args, Result, Landin.Platform.Output_Only);
      Runner.Run ("ld", Ld_Args, Result, Landin.Platform.Merged);

      declare
         First  : constant Landin.Testing.Fakes.Tool_Call :=
           Runner.Call_At (1);
         Second : constant Landin.Testing.Fakes.Tool_Call :=
           Runner.Call_At (2);
      begin
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (First.Program), "as",
            "the first program is preserved");
         Landin.Testing.Check_Equal
           (Item, Natural (First.Arguments.Length), 3,
            "the first argument count is preserved");
         Landin.Testing.Check_Equal
           (Item, First.Arguments.Element (1), "source with spaces.s",
            "an argument containing spaces stays one argument");
         Landin.Testing.Check_Equal
           (Item, First.Arguments.Element (2), "-o",
            "the first argument order is preserved");
         Landin.Testing.Check_Equal
           (Item, First.Arguments.Element (3), "out.o",
            "the last first-call argument is preserved");
         Landin.Testing.Check
           (Item, First.Capture = Landin.Platform.Output_Only,
            "the first capture mode is preserved");

         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Second.Program), "ld",
            "the second program is preserved");
         Landin.Testing.Check_Equal
           (Item, Natural (Second.Arguments.Length), 3,
            "the second argument count is preserved");
         Landin.Testing.Check_Equal
           (Item, Second.Arguments.Element (1), "out.o",
            "the first second-call argument is preserved");
         Landin.Testing.Check_Equal
           (Item, Second.Arguments.Element (2), "-o",
            "the second argument order is preserved");
         Landin.Testing.Check_Equal
           (Item, Second.Arguments.Element (3), "program",
            "the last second-call argument is preserved");
         Landin.Testing.Check
           (Item, Second.Capture = Landin.Platform.Merged,
            "the second capture mode is preserved");
      end;

      Landin.Testing.Check_Equal
        (Item, Runner.Run_Count, 2, "the complete call history is retained");
      Landin.Testing.Check_Equal
        (Item, Runner.Last_Command, "ld out.o -o program",
         "the latest command remains available as a projection");
      Landin.Testing.Check
        (Item, Runner.Last_Capture = Landin.Platform.Merged,
         "the latest capture remains available as a projection");
   end Fake_Tools_Record_Every_Call;

   procedure A_Scripted_Tool_Refuses_An_Extra_Run
     (Item : in out Landin.Testing.Context);

   procedure A_Scripted_Tool_Refuses_An_Extra_Run
     (Item : in out Landin.Testing.Context)
   is
      Runner : Landin.Testing.Fakes.Fake_Tool_Runner;
      Result : Landin.Platform.Tool_Result;
   begin
      Runner.Add_Result (0, "once");
      Runner.Run ("as", Landin.Platform.No_Arguments, Result);
      Runner.Run ("ld", Landin.Platform.No_Arguments, Result);
      Landin.Testing.Fail
        (Item, "running beyond a tool script should be refused");
   exception
      when Landin.Compiler_Defect =>
         Landin.Testing.Check_Equal
           (Item, Runner.Run_Count, 1,
            "the refused extra run is not added to history");
   end A_Scripted_Tool_Refuses_An_Extra_Run;

   procedure Set_Result_Replaces_A_Script
     (Item : in out Landin.Testing.Context);

   procedure Set_Result_Replaces_A_Script
     (Item : in out Landin.Testing.Context)
   is
      Runner : Landin.Testing.Fakes.Fake_Tool_Runner;
      First  : Landin.Platform.Tool_Result;
      Second : Landin.Platform.Tool_Result;
   begin
      Runner.Add_Result (1, "abandoned first");
      Runner.Add_Result (2, "abandoned second");
      Runner.Set_Result (4, "replacement");

      Runner.Run ("first", Landin.Platform.No_Arguments, First);
      Runner.Run ("second", Landin.Platform.No_Arguments, Second);

      Landin.Testing.Check_Equal
        (Item, First.Exit_Code, 4, "the replacement supersedes the script");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (First.Output), "replacement",
         "the replacement output supersedes the script");
      Landin.Testing.Check_Equal
        (Item, Second.Exit_Code, 4, "the replacement result repeats");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Second.Output), "replacement",
         "the replacement output repeats");
   end Set_Result_Replaces_A_Script;

   --  Touches the real filesystem, deliberately: this is the one adapter
   --  whose whole job is the host, so a fake here would test nothing.
   --  Everything it writes stays under compiler/ada/build.
   procedure Native_Round_Trips_Bytes
     (Item : in out Landin.Testing.Context);

   procedure Native_Round_Trips_Bytes
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Path    : constant String := Scratch & "/round-trip.bin";
      Listing : constant String := Scratch & "/listing";
      Text    : constant String :=
        "line one" & Character'Val (13) & Character'Val (10) & "line two";
      Content : Unbounded.Unbounded_String;
      Written : Landin.Platform.Write_Status;
      Read    : Landin.Platform.Read_Status;
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
   begin
      Ada.Directories.Create_Path (Scratch);

      Host.Write_File (Path, Text, Written);
      Landin.Testing.Check
        (Item, Written = Landin.Platform.Write_Ok, "the file was written");

      Host.Read_File (Path, Content, Read);
      Landin.Testing.Check
        (Item, Read = Landin.Platform.Read_Ok, "the file was read");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Content), Text,
         "CR LF survives a byte-oriented round trip");

      Landin.Testing.Check
        (Item, Host.Exists (Path), "the written path exists");
      Landin.Testing.Check
        (Item, Host.Is_Directory (Scratch), "the scratch path is a directory");
      Landin.Testing.Check
        (Item, not Host.Exists (Scratch & "/absent"),
         "an absent path does not exist");

      --  A directory of its own, emptied first, so the listing is the same
      --  on a fresh checkout and on a machine that has run this before.
      --  The native listing is what orders fixture discovery, so it has to
      --  be held to the contract the fake is held to.
      if Ada.Directories.Exists (Listing) then
         Ada.Directories.Delete_Tree (Listing);
      end if;

      Ada.Directories.Create_Path (Listing);
      Ada.Directories.Create_Path (Listing & "/nested");

      Host.Write_File (Listing & "/zebra.txt", "z", Written);
      Host.Write_File (Listing & "/apple.txt", "a", Written);
      Host.Write_File (Listing & "/nested/deep.txt", "d", Written);

      Host.List_Directory (Listing, Entries, Listed);

      Landin.Testing.Check
        (Item, Listed = Landin.Platform.List_Ok, "the listing path lists");
      Landin.Testing.Check_Equal
        (Item, Natural (Entries.Length), 3,
         "the native listing is immediate children only");
      Landin.Testing.Check_Equal
        (Item, Entries.Element (1), "apple.txt", "natively sorted first");
      Landin.Testing.Check_Equal
        (Item, Entries.Element (2), "nested", "natively sorted second");
      Landin.Testing.Check_Equal
        (Item, Entries.Element (3), "zebra.txt", "natively sorted third");

      Host.List_Directory (Path, Entries, Listed);
      Landin.Testing.Check
        (Item, Listed = Landin.Platform.Not_A_Directory,
         "a native file is not a directory");

      Host.Read_File (Scratch & "/absent", Content, Read);
      Landin.Testing.Check
        (Item, Read = Landin.Platform.Not_Found,
         "a missing file is reported, not raised");
   end Native_Round_Trips_Bytes;

   --  Writes through the fake are recorded rather than performed, and the
   --  recording is what a later stage will assert against.  Untested, a
   --  fake that silently dropped every write would look like a passing
   --  host.
   procedure Fake_Writes_Are_Recorded
     (Item : in out Landin.Testing.Context);

   procedure Fake_Writes_Are_Recorded
     (Item : in out Landin.Testing.Context)
   is
      Host   : Landin.Testing.Fakes.Fake_Filesystem;
      Status : Landin.Platform.Write_Status;
   begin
      Landin.Testing.Check_Equal
        (Item, Host.Written ("out.s"), "", "nothing was written yet");

      Host.Write_File ("out.s", "  ret", Status);

      Landin.Testing.Check
        (Item, Status = Landin.Platform.Write_Ok, "the write succeeded");
      Landin.Testing.Check_Equal
        (Item, Host.Written ("out.s"), "  ret", "the write was recorded");
      Landin.Testing.Check
        (Item, not Host.Exists ("out.s"),
         "a recorded write does not become a readable file");
   end Fake_Writes_Are_Recorded;

   --  The adapter owns its temporary capture, so a default-initialized
   --  runner is complete and callers do not have to arrange a persistent
   --  scratch file.
   procedure A_Default_Native_Runner_Captures_Output
     (Item : in out Landin.Testing.Context);

   procedure A_Default_Native_Runner_Captures_Output
     (Item : in out Landin.Testing.Context)
   is
      Runner    : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Arguments : Landin.Platform.Path_List;
      Result    : Landin.Platform.Tool_Result;
   begin
      Landin.Platform.Add (Arguments, "-c");
      Landin.Platform.Add (Arguments, "printf captured");
      Runner.Run ("sh", Arguments, Result);

      Landin.Testing.Check_Equal
        (Item, Result.Exit_Code, 0, "the default runner ran a tool");
      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Result.Output), "captured",
         "the default runner captured the tool output");
   end A_Default_Native_Runner_Captures_Output;

   --  Every byte value, not just the printable ones.  A reader that
   --  narrowed or sign-extended high bytes would have passed every test
   --  the suite had, because they were all ASCII.
   procedure Every_Byte_Survives (Item : in out Landin.Testing.Context);

   --  Touches the real filesystem, for the same reason.
   procedure Every_Byte_Survives (Item : in out Landin.Testing.Context) is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Path    : constant String := Scratch & "/every-byte.bin";
      All_Of  : String (1 .. 256);
      Content : Unbounded.Unbounded_String;
      Written : Landin.Platform.Write_Status;
      Read    : Landin.Platform.Read_Status;
   begin
      for Index in All_Of'Range loop
         All_Of (Index) := Character'Val (Index - 1);
      end loop;

      Ada.Directories.Create_Path (Scratch);
      Host.Write_File (Path, All_Of, Written);
      Host.Read_File (Path, Content, Read);

      Landin.Testing.Check
        (Item, Written = Landin.Platform.Write_Ok, "every byte was written");
      Landin.Testing.Check
        (Item, Read = Landin.Platform.Read_Ok, "every byte was read");
      Landin.Testing.Check_Equal
        (Item, Unbounded.Length (Content), 256,
         "all 256 bytes came back");
      Landin.Testing.Check
        (Item, Unbounded.To_String (Content) = All_Of,
         "and each one came back unchanged");
   end Every_Byte_Survives;

   --  A directory is not a readable file, and neither is a device.  The
   --  reader used to accept anything that existed, so `refine /dev/zero`
   --  never returned.
   procedure Only_Ordinary_Files_Are_Read
     (Item : in out Landin.Testing.Context);

   --  Touches the real filesystem, and reads a real device node when the
   --  host has one.
   procedure Only_Ordinary_Files_Are_Read
     (Item : in out Landin.Testing.Context)
   is
      Host    : Landin.Platform.Native.Native_Filesystem;
      Content : Unbounded.Unbounded_String;
      Read    : Landin.Platform.Read_Status;
   begin
      Ada.Directories.Create_Path (Scratch);

      Host.Read_File (Scratch, Content, Read);
      Landin.Testing.Check
        (Item, Read = Landin.Platform.Not_Readable,
         "a directory is not readable as a file");

      --  /dev/zero exists on every host this runs on and would never end.
      if Host.Exists ("/dev/zero") then
         Host.Read_File ("/dev/zero", Content, Read);
         Landin.Testing.Check
           (Item, Read = Landin.Platform.Not_Readable,
            "a character device is refused rather than read forever");
         Landin.Testing.Check_Equal
           (Item, Unbounded.Length (Content), 0,
            "and nothing was taken from it");
      else
         Landin.Testing.Check
           (Item, True, "this host has no /dev/zero to refuse");
      end if;
   end Only_Ordinary_Files_Are_Read;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "platform", "fake reads report their reason",
         Fake_Reads_Report_Their_Reason'Access);
      Landin.Testing.Register
        (Into, "platform", "fake listings are sorted and shallow",
         Fake_Listings_Are_Sorted_And_Shallow'Access);
      Landin.Testing.Register
        (Into, "platform", "fake tools record their command",
         Fake_Tools_Record_Their_Command'Access);
      Landin.Testing.Register
        (Into, "platform", "set result remains sticky",
         Set_Result_Remains_Sticky'Access);
      Landin.Testing.Register
        (Into, "platform", "fake tools return scripted results in order",
         Fake_Tools_Return_Scripted_Results_In_Order'Access);
      Landin.Testing.Register
        (Into, "platform", "fake tools record every call",
         Fake_Tools_Record_Every_Call'Access);
      Landin.Testing.Register
        (Into, "platform", "a scripted tool refuses an extra run",
         A_Scripted_Tool_Refuses_An_Extra_Run'Access);
      Landin.Testing.Register
        (Into, "platform", "set result replaces a script",
         Set_Result_Replaces_A_Script'Access);
      Landin.Testing.Register
        (Into, "platform", "native round trips bytes",
         Native_Round_Trips_Bytes'Access);
      Landin.Testing.Register
        (Into, "platform", "fake writes are recorded",
         Fake_Writes_Are_Recorded'Access);
      Landin.Testing.Register
        (Into, "platform", "a default native runner captures output",
         A_Default_Native_Runner_Captures_Output'Access);
      Landin.Testing.Register
        (Into, "platform", "every byte survives",
         Every_Byte_Survives'Access);
      Landin.Testing.Register
        (Into, "platform", "only ordinary files are read",
         Only_Ordinary_Files_Are_Read'Access);
   end Register;

end Landin.Tests.Platform_Suite;
