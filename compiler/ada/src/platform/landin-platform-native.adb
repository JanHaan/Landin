with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Interfaces.C;
with Interfaces;
with System;

package body Landin.Platform.Native is

   package Directories renames Ada.Directories;
   package Stream_IO renames Ada.Streams.Stream_IO;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Ada.Directories.File_Kind;
   use type Ada.Streams.Stream_Element_Offset;

   --  One buffer size for both directions.  64 KiB is large enough that the
   --  syscall count stops mattering and small enough to sit in a frame.
   Chunk_Size : constant := 64 * 1024;

   overriding function Exists
     (Host : Native_Filesystem; Path : String) return Boolean
   is
      pragma Unreferenced (Host);
   begin
      return Directories.Exists (Path);
   exception
      when Ada.IO_Exceptions.Name_Error =>
         return False;
   end Exists;

   overriding function Same_File
     (Host : Native_Filesystem; Left, Right : String) return Boolean
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Same_Existing_Object
        (Left, Right : Interfaces.C.char_array) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_same_existing_file";
   begin
      if Left = "" or else Right = ""
        or else (for some Byte of Left => Byte = Character'Val (0))
        or else (for some Byte of Right => Byte = Character'Val (0))
      then
         return False;
      end if;
      return Same_Existing_Object
        (Interfaces.C.To_C (Left), Interfaces.C.To_C (Right)) = 1;
   end Same_File;

   overriding function Existing_File_Key
     (Host : Native_Filesystem; Path : String) return String
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Key_Of
        (Name   : Interfaces.C.char_array;
         Key    : out Interfaces.C.char_array;
         Length : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_existing_file_key";
      Buffer_Size : constant Interfaces.C.size_t := 128;
      Buffer : Interfaces.C.char_array (0 .. 127);
   begin
      if Path = ""
        or else (for some Byte of Path => Byte = Character'Val (0))
      then
         return "";
      end if;
      if Key_Of (Interfaces.C.To_C (Path), Buffer, Buffer_Size) /= 0 then
         return "";
      end if;
      return Interfaces.C.To_Ada (Buffer);
   end Existing_File_Key;

   overriding function Identity_Of
     (Host : Native_Filesystem; Path : String) return File_Identity
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Get_Identity
        (Name : Interfaces.C.char_array;
         Device, Inode : access Interfaces.Unsigned_64)
         return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_file_identity";
      Result : File_Identity;
      Device : aliased Interfaces.Unsigned_64;
      Inode : aliased Interfaces.Unsigned_64;
   begin
      if Path = "" or else
        (for some Byte of Path => Byte = Character'Val (0))
      then
         return Result;
      end if;
      Result.Valid := Get_Identity
        (Interfaces.C.To_C (Path), Device'Access, Inode'Access) = 1;
      if Result.Valid then
         Result.Device := Device;
         Result.Inode := Inode;
      end if;
      return Result;
   end Identity_Of;

   overriding function Paths_Overlap
     (Host : Native_Filesystem; Left, Right : String) return Boolean
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Same_Object
        (Left, Right : Interfaces.C.char_array) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_same_file";
   begin
      --  Only the host namespace can resolve symlinks followed by ".." or
      --  compare missing names on the destination filesystem. Unknown is
      --  overlapping: never turn an identity lookup error into permission
      --  to overwrite another artifact.
      if Left = "" or else Right = ""
        or else (for some Byte of Left => Byte = Character'Val (0))
        or else (for some Byte of Right => Byte = Character'Val (0))
      then
         return True;
      end if;
      return Same_Object
        (Interfaces.C.To_C (Left), Interfaces.C.To_C (Right)) /= 0;
   end Paths_Overlap;

   overriding function Working_Directory
     (Host : Native_Filesystem) return String
   is
      pragma Unreferenced (Host);
   begin
      return Directories.Current_Directory;
   end Working_Directory;

   overriding function Is_Directory
     (Host : Native_Filesystem; Path : String) return Boolean
   is
      pragma Unreferenced (Host);
   begin
      return Directories.Exists (Path)
        and then Directories.Kind (Path) = Directories.Directory;
   exception
      when Ada.IO_Exceptions.Name_Error =>
         return False;
   end Is_Directory;

   ---------------------------------------------------------------------
   --  Read_File
   --
   --  Stream_IO, not Text_IO: a source file is bytes.  Reading it as text
   --  would translate line endings, and every span taken afterwards would
   --  point at a byte that is not in the file.
   ---------------------------------------------------------------------

   --  Cleanup after an ordinary I/O failure must not replace that result
   --  with another expected close failure. Programming and resource failures
   --  remain exceptions; this helper is not a catch-all recovery boundary.
   procedure Close_After_Failure (File : in out Stream_IO.File_Type);

   procedure Close_After_Failure (File : in out Stream_IO.File_Type) is
   begin
      if Stream_IO.Is_Open (File) then
         Stream_IO.Close (File);
      end if;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.Device_Error =>
         null;
   end Close_After_Failure;

   overriding procedure Read_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Read_Status)
   is
      pragma Unreferenced (Host);
      File : Stream_IO.File_Type;
   begin
      Content := Unbounded.Null_Unbounded_String;

      if not Directories.Exists (Path) then
         Status := Not_Found;
         return;
      end if;

      --  Ordinary files only.  A FIFO or a character device answers a read
      --  forever, and a compiler that will happily read /dev/zero into a
      --  source snapshot does not fail, it hangs.
      if Directories.Kind (Path) /= Directories.Ordinary_File then
         Status := Not_Readable;
         return;
      end if;

      --  Its own stream, even if this process already has the file open.
      --  Without a sharing form GNAT refuses a second open of the same full
      --  name with Use_Error, so two test workers reading one fixture's
      --  golden at once saw it as unreadable, one run in four on the gate.
      --  A read never needs another opener's position.
      Stream_IO.Open (File, Stream_IO.In_File, Path, Form => "shared=no");

      loop
         declare
            Buffer : Ada.Streams.Stream_Element_Array (1 .. Chunk_Size);
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            Stream_IO.Read (File, Buffer, Last);
            exit when Last < Buffer'First;

            declare
               Chunk : String (1 .. Natural (Last));
            begin
               for Index in Buffer'First .. Last loop
                  Chunk (Natural (Index)) :=
                    Character'Val (Natural (Buffer (Index)));
               end loop;
               Unbounded.Append (Content, Chunk);
            end;

            exit when Last < Buffer'Last;
         end;
      end loop;

      Stream_IO.Close (File);
      Status := Read_Ok;

   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.Device_Error =>
         Close_After_Failure (File);
         Status := Not_Readable;
   end Read_File;

   overriding procedure Write_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status)
   is
      pragma Unreferenced (Host);
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Create (File, Stream_IO.Out_File, Path);

      --  Chunked, for the same reason reads are: the payload may be an
      --  object file, and one stack frame is not the right place for it.
      declare
         Chunk  : Ada.Streams.Stream_Element_Array (1 .. Chunk_Size);
         Filled : Ada.Streams.Stream_Element_Offset := 0;
      begin
         for Index in Content'Range loop
            Filled := Filled + 1;
            Chunk (Filled) :=
              Ada.Streams.Stream_Element (Character'Pos (Content (Index)));

            if Filled = Chunk'Last then
               Stream_IO.Write (File, Chunk (1 .. Filled));
               Filled := 0;
            end if;
         end loop;

         if Filled > 0 then
            Stream_IO.Write (File, Chunk (1 .. Filled));
         end if;
      end;

      Stream_IO.Close (File);
      Status := Write_Ok;

   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.Device_Error =>
         Close_After_Failure (File);
         Status := Not_Writable;
   end Write_File;

   overriding procedure Replace_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Replace_Existing
        (Name : Interfaces.C.char_array;
         Data : System.Address;
         Size : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_replace_existing_file";
      Data : constant System.Address :=
        (if Content'Length = 0 then System.Null_Address
         else Content (Content'First)'Address);
   begin
      if Path = "" or else
        (for some Byte of Path => Byte = Character'Val (0))
      then
         Status := Not_Writable;
      elsif Replace_Existing
        (Interfaces.C.To_C (Path), Data,
         Interfaces.C.size_t (Content'Length)) = 0
      then
         Status := Write_Ok;
      else
         Status := Not_Writable;
      end if;
   end Replace_File;

   overriding procedure Remove_File
     (Host   : Native_Filesystem;
      Path   : String;
      Status : out Remove_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Unlink_File (Name : Interfaces.C.char_array)
        return Interfaces.C.int
        with Import, Convention => C, External_Name => "landin_unlink_file";
      Result : Interfaces.C.int;
   begin
      Result := Unlink_File (Interfaces.C.To_C (Path));
      Status := (if Result = 1 then Removed
                 elsif Result = 0 then Already_Absent
                 else Not_Removable);
   end Remove_File;

   overriding procedure Move_File
     (Host   : Native_Filesystem;
      From, To : String;
      Status : out Move_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Move_No_Replace
        (Source, Destination : Interfaces.C.char_array)
         return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_move_file_noreplace";
      Result : Interfaces.C.int;
   begin
      Result := Move_No_Replace
        (Interfaces.C.To_C (From), Interfaces.C.To_C (To));
      Status := (if Result = 1 then Moved
                 elsif Result = 0 then Move_Source_Absent
                 else Not_Movable);
   end Move_File;

   overriding procedure Lock_Output
     (Host : Native_Filesystem; Path : String; Handle : out Integer)
   is
      pragma Unreferenced (Host);
      function Lock_Directory (Name : Interfaces.C.char_array)
        return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_lock_output_directory";
   begin
      Handle := Integer (Lock_Directory (Interfaces.C.To_C (Path)));
   end Lock_Output;

   overriding procedure Unlock_Output
     (Host : Native_Filesystem; Handle : Integer)
   is
      pragma Unreferenced (Host);
      procedure Unlock_Directory (Value : Interfaces.C.int)
        with Import, Convention => C,
             External_Name => "landin_unlock_output_directory";
   begin
      Unlock_Directory (Interfaces.C.int (Handle));
   end Unlock_Output;

   ---------------------------------------------------------------------
   --  List_Directory
   --
   --  Sorted by name.  Directory order is a host detail, and a test suite
   --  whose order depends on it is a test suite that passes on one machine.
   ---------------------------------------------------------------------

   overriding procedure List_Directory
     (Host    : Native_Filesystem;
      Path    : String;
      Entries : out Path_List;
      Status  : out List_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;

      package Sorting is new Path_Vectors.Generic_Sorting ("<" => "<");

      Search : Directories.Search_Type;
      Item   : Directories.Directory_Entry_Type;
      function Access_Denied
        (Path : Interfaces.C.char_array) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_directory_access_denied";
   begin
      Entries := Path_Vectors.Empty_Vector;

      if not Directories.Exists (Path) then
         Status :=
           (if Access_Denied (Interfaces.C.To_C (Path)) /= 0
            then Directory_Not_Readable else Directory_Not_Found);
         return;
      end if;

      if Directories.Kind (Path) /= Directories.Directory then
         Status := Not_A_Directory;
         return;
      end if;

      Directories.Start_Search
        (Search, Path, "*",
         Filter => [Directories.Ordinary_File => True,
                    Directories.Directory     => True,
                    Directories.Special_File  => False]);

      while Directories.More_Entries (Search) loop
         Directories.Get_Next_Entry (Search, Item);

         declare
            Name : constant String := Directories.Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               Entries.Append (Name);
            end if;
         end;
      end loop;

      Directories.End_Search (Search);
      Sorting.Sort (Entries);
      Status := List_Ok;

   exception
      when Ada.IO_Exceptions.Name_Error =>
         Status :=
           (if Access_Denied (Interfaces.C.To_C (Path)) /= 0
            then Directory_Not_Readable else Directory_Not_Found);
      when Ada.IO_Exceptions.Use_Error | Ada.IO_Exceptions.Device_Error =>
         Status := Directory_Not_Readable;
   end List_Directory;

   overriding function Sample (Host : Native_Meter) return Resource_Sample
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      use type Interfaces.C.long_long;
      function Usage
        (Processor : out Interfaces.C.long_long;
         Peak      : out Interfaces.C.long_long) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_resource_usage";
      function Allocated return Interfaces.C.long_long
        with Import, Convention => C,
             External_Name => "landin_allocated_bytes";
      Processor, Peak : Interfaces.C.long_long;
      Held : Interfaces.C.long_long;
   begin
      if Usage (Processor, Peak) /= 0 then
         raise Host_Exhausted with "the host refused its resource counters";
      end if;
      Held := Allocated;
      if Held < 0 then
         raise Host_Exhausted with "the host refused its allocator's count";
      end if;
      return (Processor_Microseconds => Long_Long_Integer (Processor),
              Peak_Resident_KiB      => Long_Long_Integer (Peak),
              Allocated_Bytes        => Long_Long_Integer (Held));
   end Sample;

   ---------------------------------------------------------------------
   --  The channel
   ---------------------------------------------------------------------

   function Channel_Read
     (Into : System.Address; Length : Interfaces.C.long)
      return Interfaces.C.long
     with Import, Convention => C, External_Name => "landin_channel_read";

   function Channel_Pending return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_channel_pending";

   function Channel_Write
     (Descriptor : Interfaces.C.int;
      Item       : System.Address;
      Length     : Interfaces.C.long) return Interfaces.C.int
     with Import, Convention => C, External_Name => "landin_channel_write";

   procedure Write_To (Descriptor : Interfaces.C.int; Item : String);

   procedure Write_To (Descriptor : Interfaces.C.int; Item : String) is
      use type Interfaces.C.int;
   begin
      if Item'Length > 0
        and then Channel_Write
          (Descriptor, Item (Item'First)'Address,
           Interfaces.C.long (Item'Length)) /= 0
      then
         raise Host_Exhausted with "the host refused a write";
      end if;
   end Write_To;

   overriding procedure Read
     (Host : in out Native_Channel;
      Into : out String;
      Last : out Natural)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.long;
      Got : Interfaces.C.long;
   begin
      if Into'Length = 0 then
         Last := Into'First - 1;
         return;
      end if;
      Got := Channel_Read
        (Into (Into'First)'Address, Interfaces.C.long (Into'Length));
      if Got < 0 then
         raise Host_Exhausted with "the host refused a read";
      end if;
      Last := Into'First + Natural (Got) - 1;
   end Read;

   overriding function Pending (Host : in out Native_Channel) return Boolean
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      Ready : constant Interfaces.C.int := Channel_Pending;
   begin
      if Ready < 0 then
         raise Host_Exhausted with "the host refused to poll its input";
      end if;
      return Ready > 0;
   end Pending;

   overriding procedure Write (Host : in out Native_Channel; Item : String)
   is
      pragma Unreferenced (Host);
   begin
      Write_To (1, Item);
   end Write;

   overriding procedure Log (Host : in out Native_Channel; Line : String) is
      pragma Unreferenced (Host);
   begin
      Write_To (2, Line & ASCII.LF);
   end Log;

end Landin.Platform.Native;
