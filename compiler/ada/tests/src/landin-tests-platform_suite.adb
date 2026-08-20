with Ada.Directories;
with Ada.Strings.Unbounded;

with Landin.Platform.Native;
with Landin.Platform.Native.Tools;
with Landin.Testing.Fakes;

package body Landin.Tests.Platform_Suite is

   package Unbounded renames Ada.Strings.Unbounded;

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

   --  The real runner has no scratch directory unless Create gave it one,
   --  and finding that out by indexing an empty vector is not a diagnosis.
   procedure An_Unconfigured_Runner_Refuses
     (Item : in out Landin.Testing.Context);

   procedure An_Unconfigured_Runner_Refuses
     (Item : in out Landin.Testing.Context)
   is
      Runner : Landin.Platform.Native.Tools.Native_Tool_Runner;
      Result : Landin.Platform.Tool_Result;
   begin
      Runner.Run ("true", Landin.Platform.No_Arguments, Result);
      Landin.Testing.Fail
        (Item, "a runner with no scratch directory should refuse");
   exception
      when Landin.Compiler_Defect =>
         Landin.Testing.Check
           (Item, True, "an unconfigured tool runner refuses to run");
   end An_Unconfigured_Runner_Refuses;

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
        (Into, "platform", "native round trips bytes",
         Native_Round_Trips_Bytes'Access);
      Landin.Testing.Register
        (Into, "platform", "fake writes are recorded",
         Fake_Writes_Are_Recorded'Access);
      Landin.Testing.Register
        (Into, "platform", "an unconfigured runner refuses",
         An_Unconfigured_Runner_Refuses'Access);
      Landin.Testing.Register
        (Into, "platform", "every byte survives",
         Every_Byte_Survives'Access);
      Landin.Testing.Register
        (Into, "platform", "only ordinary files are read",
         Only_Ordinary_Files_Are_Read'Access);
   end Register;

end Landin.Tests.Platform_Suite;
