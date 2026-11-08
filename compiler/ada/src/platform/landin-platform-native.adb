with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with GNAT.OS_Lib;
with Landin.Platform.Native.Byte_Strings;
with Ada.Strings.Fixed;
with Ada.Streams.Stream_IO;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
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

   function Diagnostic_Color return Boolean is
      use type Interfaces.C.int;
      function Isatty (Descriptor : Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "isatty";
   begin
      return Isatty (2) /= 0
        and then not Ada.Environment_Variables.Exists ("NO_COLOR")
        and then Ada.Environment_Variables.Value ("TERM", "") /= "dumb";
   end Diagnostic_Color;

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

   overriding function Observe_Identity
     (Host : Native_Filesystem; Path : String) return Identity_Observation
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Observe
        (Name : Interfaces.C.char_array;
         Device, Inode : access Interfaces.Unsigned_64;
         Parent : access Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_observe_identity";
      Result : Identity_Observation;
      Device, Inode : aliased Interfaces.Unsigned_64;
      Found : Interfaces.C.int;
      Parent : aliased Interfaces.C.int := 0;
   begin
      if Path = "" or else
        (for some Byte of Path => Byte = Character'Val (0))
      then
         return Result;
      end if;
      Found := Observe
        (Interfaces.C.To_C (Path), Device'Access, Inode'Access, Parent'Access);
      if Found = 1 then
         Result.Identity := (Device => Device, Inode => Inode, Valid => True);
         Result.Status := Read_Ok;
      elsif Found = 0 then
         Result.Status := Not_Found;
         Result.Parent_Resolved := Parent /= 0;
      end if;
      return Result;
   end Observe_Identity;

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

   overriding function Existing_Identity
     (Host : Native_Filesystem; Path : String) return File_Identity
     is (Identity_Of (Host, Path));

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

   overriding function Paths_Overlap_Any
     (Host : Native_Filesystem; Left : String; Rights : Path_List)
      return Boolean
   is
      pragma Unreferenced (Host);
      package C renames Interfaces.C;
      package Strings renames Interfaces.C.Strings;
      use type C.int;
      Paths : aliased Strings.chars_ptr_array
        (1 .. C.size_t (Rights.Length)) := [others => Strings.Null_Ptr];
      function Overlaps_Any
        (Destination : C.char_array;
         Sources : System.Address;
         Count : C.size_t) return C.int
        with Import, Convention => C,
             External_Name => "landin_overlaps_any";
      Overlap : Boolean;
   begin
      if Rights.Is_Empty then
         return False;
      end if;
      if Left = ""
        or else (for some Byte of Left => Byte = Character'Val (0))
      then
         return True;
      end if;
      for Index in Paths'Range loop
         declare
            Right : constant String := Rights (Positive (Index));
         begin
            if Right = ""
              or else (for some Byte of Right => Byte = Character'Val (0))
            then
               for Free_Index in Paths'Range loop
                  Strings.Free (Paths (Free_Index));
               end loop;
               return True;
            end if;
            Paths (Index) := Strings.New_String (Right);
         end;
      end loop;
      Overlap := Overlaps_Any
        (C.To_C (Left), Paths'Address, C.size_t (Rights.Length)) /= 0;
      for Index in Paths'Range loop
         Strings.Free (Paths (Index));
      end loop;
      return Overlap;
   exception
      when others =>
         for Index in Paths'Range loop
            Strings.Free (Paths (Index));
         end loop;
         raise;
   end Paths_Overlap_Any;

   overriding function Working_Directory
     (Host : Native_Filesystem) return String
   is
      pragma Unreferenced (Host);
   begin
      return Directories.Current_Directory;
   end Working_Directory;

   overriding function Executable_Directory
     (Host : Native_Filesystem) return String
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Executable_Path
        (Into : out Interfaces.C.char_array;
         Length : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_executable_path";
      Buffer_Size : constant Interfaces.C.size_t := 4096;
      Buffer : Interfaces.C.char_array (0 .. 4095);
   begin
      if Executable_Path (Buffer, Buffer_Size) /= 0 then
         return "";
      end if;
      declare
         Path : constant String := Interfaces.C.To_Ada (Buffer);
         Slash : constant Natural := Ada.Strings.Fixed.Index
           (Path, "/", Ada.Strings.Backward);
      begin
         --  Only an absolute name says where the executable is.
         if Path = "" or else Path (Path'First) /= '/' then
            return "";
         elsif Slash = Path'First then
            return "/";
         end if;
         return Path (Path'First .. Slash - 1);
      end;
   end Executable_Directory;

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

   overriding function Is_Link
     (Host : Native_Filesystem; Path : String) return Boolean
   is
      pragma Unreferenced (Host);
   begin
      return GNAT.OS_Lib.Is_Symbolic_Link (Path);
   end Is_Link;

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
     (Host : Native_Filesystem; Path : String;
      Content : out Unbounded.Unbounded_String; Status : out Read_Status)
   is
      Identity : File_Identity;
   begin
      Read_Snapshot (Host, Path, Content, Identity, Status);
   end Read_File;

   overriding procedure Write_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status)
   is
      Reason : Unbounded.Unbounded_String;
   begin
      Write_File (Host, Path, Content, Status, Reason);
   end Write_File;

   overriding procedure Write_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status;
      Reason  : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host);
      File : Stream_IO.File_Type;
      use type Interfaces.C.int;
      function Stage_Write
        (Path, Content : Interfaces.C.char_array;
         Size : Interfaces.C.size_t;
         Said : out Interfaces.C.char_array;
         Room : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_publication_stage_write_reason";
      function Private_Write
        (Path, Content : Interfaces.C.char_array;
         Size : Interfaces.C.size_t;
         Said : out Interfaces.C.char_array;
         Room : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_private_write_reason";
      Staged : Interfaces.C.int;
      Said : Interfaces.C.char_array (1 .. 4096) :=
        [others => Interfaces.C.nul];
   begin
      Reason := Unbounded.Null_Unbounded_String;
      Staged := Stage_Write
        (Interfaces.C.To_C (Path), Interfaces.C.To_C (Content),
         Content'Length, Said, Said'Length);
      if Staged = -2 then
         Staged := Private_Write
           (Interfaces.C.To_C (Path), Interfaces.C.To_C (Content),
            Content'Length, Said, Said'Length);
      end if;
      if Staged /= -2 then
         Status := (if Staged = 0 then Write_Ok else Not_Writable);
         Reason := Unbounded.To_Unbounded_String (Interfaces.C.To_Ada (Said));
         return;
      end if;
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
      when Failure : Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.Device_Error =>
         Reason := Unbounded.To_Unbounded_String
           (Ada.Exceptions.Exception_Message (Failure));
         Close_After_Failure (File);
         Status := Not_Writable;
   end Write_File;

   overriding procedure Replace_File
     (Host    : Native_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Write_Status;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      use type Interfaces.C.size_t;
      function Replace_Existing
        (Name   : Interfaces.C.char_array;
         Data   : System.Address;
         Size   : Interfaces.C.size_t;
         Said   : out Interfaces.C.char_array;
         Room   : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_replace_existing_file";
      Data : constant System.Address :=
        (if Content'Length = 0 then System.Null_Address
         else Content (Content'First)'Address);
      --  A cause names at most one path, its copy's, which the system may
      --  have made absolute and so longer than Path.
      Said : Interfaces.C.char_array
        (1 .. Interfaces.C.size_t (Path'Length) + 4096) :=
        [others => Interfaces.C.nul];
      Room : constant Interfaces.C.size_t := Said'Length;
   begin
      if Path = "" or else
        (for some Byte of Path => Byte = Character'Val (0))
      then
         Status := Not_Writable;
         Reason := Ada.Strings.Unbounded.To_Unbounded_String
           ("its name cannot be given to the system");
      elsif Replace_Existing
        (Interfaces.C.To_C (Path), Data,
         Interfaces.C.size_t (Content'Length), Said, Room) = 0
      then
         Status := Write_Ok;
         Reason := Ada.Strings.Unbounded.Null_Unbounded_String;
      else
         Status := Not_Writable;
         Reason := Ada.Strings.Unbounded.To_Unbounded_String
           (Interfaces.C.To_Ada (Said));
      end if;
   end Replace_File;

   overriding procedure Open_Publication
     (Host : Native_Filesystem; Path : String; Delete_Only : Boolean;
      Root : String; Handle : out Publication_Handle;
      Stage : out Unbounded.Unbounded_String; Status : out Write_Status;
      Reason : out Unbounded.Unbounded_String;
      Require_Absent : Boolean := False)
   is
      pragma Unreferenced (Host);
      package C renames Interfaces.C;
      use type C.int;
      function Open_Transaction
        (Path : C.char_array; Deletion : C.int; Root : C.char_array;
         Handle : out C.int; Stage : out C.char_array; Stage_Room : C.size_t;
         Reason : out C.char_array; Reason_Room : C.size_t) return C.int
        with Import, Convention => C,
             External_Name => "landin_publication_open";
      Token : C.int;
      Stage_Buffer, Reason_Buffer : C.char_array (0 .. 8191);
      Result : C.int;
   begin
      Result := Open_Transaction
        (C.To_C (Path), Boolean'Pos (Delete_Only)
         + 2 * Boolean'Pos (Require_Absent), C.To_C (Root), Token,
         Stage_Buffer, Stage_Buffer'Length, Reason_Buffer,
         Reason_Buffer'Length);
      Handle := Publication_Handle (Token);
      Stage := Unbounded.To_Unbounded_String (C.To_Ada (Stage_Buffer));
      Reason := Unbounded.To_Unbounded_String (C.To_Ada (Reason_Buffer));
      Status := (if Result = 0 then Write_Ok else Not_Writable);
   end Open_Publication;

   overriding procedure Advance_Publication
     (Host : Native_Filesystem; Handle : Publication_Handle;
      Action : Publication_Action; Protected_Paths : Path_List;
      Protected_Identities : Identity_List; Status : out Write_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host);
      package C renames Interfaces.C;
      package Strings renames Interfaces.C.Strings;
      use type C.int;
      Paths : aliased Strings.chars_ptr_array
        (1 .. C.size_t (Protected_Paths.Length)) :=
          [others => Strings.Null_Ptr];
      type Identity_Array is array (Positive range <>) of
        Interfaces.Unsigned_64 with Convention => C;
      Identities : aliased Identity_Array
        (1 .. 2 * Natural (Protected_Identities.Length));
      Buffer : C.char_array (0 .. 8191);
      Result : C.int;
      function Step
        (Handle, Action : C.int; Paths : System.Address; Count : C.size_t;
         Identities : System.Address; Identity_Count : C.size_t;
         Reason : out C.char_array; Room : C.size_t) return C.int
        with Import, Convention => C,
             External_Name => "landin_publication_step";
   begin
      for Index in Paths'Range loop
         Paths (Index) := Strings.New_String
           (Protected_Paths (Positive (Index)));
      end loop;
      for Index in 1 .. Natural (Protected_Identities.Length) loop
         Identities (2 * Index - 1) := Protected_Identities (Index).Device;
         Identities (2 * Index) := Protected_Identities (Index).Inode;
      end loop;
      Result := Step
        (C.int (Handle), C.int (Publication_Action'Pos (Action)),
         Paths'Address, Paths'Length, Identities'Address,
         C.size_t (Protected_Identities.Length), Buffer, Buffer'Length);
      Reason := Unbounded.To_Unbounded_String (C.To_Ada (Buffer));
      Status := (if Result = 0 then Write_Ok else Not_Writable);
      for Index in Paths'Range loop
         Strings.Free (Paths (Index));
      end loop;
   exception
      when others =>
         for Index in Paths'Range loop
            Strings.Free (Paths (Index));
         end loop;
         raise;
   end Advance_Publication;

   overriding function Cancellation_Requested
     (Host : Native_Filesystem) return Boolean
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Requested return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_cancellation_requested";
   begin
      return Requested /= 0;
   end Cancellation_Requested;

   overriding procedure Read_Snapshot
     (Host : Native_Filesystem; Path : String;
      Content : out Unbounded.Unbounded_String;
      Identity : out File_Identity; Status : out Read_Status)
   is
      pragma Unreferenced (Host);
      package C renames Interfaces.C;
      package Strings renames Interfaces.C.Strings;
      use type C.int;
      function Read_Actual
        (Path : C.char_array; Bytes : out Strings.chars_ptr;
         Size : out C.size_t; Device, Inode : out Interfaces.Unsigned_64)
         return C.int
        with Import, Convention => C,
             External_Name => "landin_read_snapshot";
      procedure Free_Bytes (Bytes : Strings.chars_ptr)
        with Import, Convention => C,
             External_Name => "landin_snapshot_free";
      Bytes : Strings.chars_ptr := Strings.Null_Ptr;
      Size : C.size_t;
      Result : C.int;
   begin
      Content := Unbounded.Null_Unbounded_String;
      Identity := (others => <>);
      Result := Read_Actual
        (C.To_C (Path), Bytes, Size, Identity.Device, Identity.Inode);
      if Result = 0 then
         Content := Byte_Strings.Copy (Bytes, Size);
         Identity.Valid := True;
         Free_Bytes (Bytes);
         Status := Read_Ok;
      else
         Status := (if Result = 1 then Not_Found else Not_Readable);
      end if;
   end Read_Snapshot;

   overriding procedure Read_For_Update
     (Host : Native_Filesystem; Path : String;
      Content : out Unbounded.Unbounded_String;
      Lease : out Update_Handle; Status : out Read_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host);
      package C renames Interfaces.C;
      package Strings renames Interfaces.C.Strings;
      use type C.int;
      function Open_Update
        (Path : C.char_array; Bytes : out Strings.chars_ptr;
         Size : out C.size_t; Token : out C.int;
         Reason : out C.char_array; Room : C.size_t) return C.int
        with Import, Convention => C,
             External_Name => "landin_open_update";
      procedure Free_Bytes (Bytes : Strings.chars_ptr)
        with Import, Convention => C,
             External_Name => "landin_snapshot_free";
      Bytes : Strings.chars_ptr := Strings.Null_Ptr;
      Size : C.size_t;
      Token, Result : C.int;
      Buffer : C.char_array (0 .. 8191);
   begin
      Content := Unbounded.Null_Unbounded_String;
      Result := Open_Update
        (C.To_C (Path), Bytes, Size, Token, Buffer, Buffer'Length);
      Lease := Update_Handle (Token);
      Reason := Unbounded.To_Unbounded_String (C.To_Ada (Buffer));
      if Result = 0 then
         Content := Byte_Strings.Copy (Bytes, Size);
         Free_Bytes (Bytes);
         Status := Read_Ok;
      else
         Status := (if Result = 1 then Not_Found else Not_Readable);
      end if;
   end Read_For_Update;

   overriding procedure Replace_Update
     (Host : Native_Filesystem; Lease : Update_Handle; Content : String;
      Status : out Write_Status; Reason : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host);
      package C renames Interfaces.C;
      use type C.int;
      function Replace_Lease
        (Token : C.int; Data : C.char_array; Size : C.size_t;
         Reason : out C.char_array; Room : C.size_t) return C.int
        with Import, Convention => C,
             External_Name => "landin_replace_update";
      Buffer : C.char_array (0 .. 8191);
      Result : C.int;
   begin
      Result := Replace_Lease
        (C.int (Lease), C.To_C (Content), Content'Length, Buffer,
         Buffer'Length);
      Reason := Unbounded.To_Unbounded_String (C.To_Ada (Buffer));
      Status := (if Result = 0 then Write_Ok else Not_Writable);
   end Replace_Update;

   overriding function Update_Identity
     (Host : Native_Filesystem; Lease : Update_Handle) return File_Identity
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Lease_Identity
        (Token : Interfaces.C.int;
         Device, Inode : out Interfaces.Unsigned_64) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_update_identity";
      Result : File_Identity;
   begin
      Result.Valid := Lease_Identity
        (Interfaces.C.int (Lease), Result.Device, Result.Inode) = 0;
      return Result;
   end Update_Identity;

   overriding procedure Close_Update
     (Host : Native_Filesystem; Lease : Update_Handle)
   is
      pragma Unreferenced (Host);
      procedure Close_Lease (Token : Interfaces.C.int)
        with Import, Convention => C, External_Name => "landin_close_update";
   begin
      Close_Lease (Interfaces.C.int (Lease));
   end Close_Update;

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

   overriding procedure Make_Directory
     (Host   : Native_Filesystem;
      Path   : String;
      Status : out Write_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Private_Mkdir (Path : Interfaces.C.char_array)
         return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_private_mkdir";
      function Stage_Mkdir (Path : Interfaces.C.char_array)
         return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_publication_stage_mkdir";
      Result : Interfaces.C.int;
   begin
      Result := Stage_Mkdir (Interfaces.C.To_C (Path));
      if Result /= -2 then
         Status := (if Result = 0 then Write_Ok else Not_Writable);
         return;
      end if;
      Result := Private_Mkdir (Interfaces.C.To_C (Path));
      if Result /= -2 then
         Status := (if Result = 0 then Write_Ok else Not_Writable);
         return;
      end if;
      if Ada.Directories.Exists (Path) then
         Status :=
           (if Ada.Directories.Kind (Path) = Ada.Directories.Directory
            then Write_Ok else Not_Writable);
         return;
      end if;
      Ada.Directories.Create_Directory (Path);
      Status := Write_Ok;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         Status := Not_Writable;
   end Make_Directory;

   overriding procedure Make_Private_Directory
     (Host   : Native_Filesystem;
      Prefix : String;
      Path   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Write_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Private_Directory
        (Name     : Interfaces.C.char_array;
         Into     : out Interfaces.C.char_array;
         Capacity : Interfaces.C.size_t) return Interfaces.C.int
        with Import, Convention => C,
             External_Name => "landin_private_directory";
      Made : Interfaces.C.char_array (0 .. 4095);
      Named : constant Interfaces.C.char_array := Interfaces.C.To_C (Prefix);
      Capacity : constant Interfaces.C.size_t := Made'Length;
   begin
      if Private_Directory (Named, Made, Capacity) = 0 then
         Path := Ada.Strings.Unbounded.To_Unbounded_String
           (Interfaces.C.To_Ada (Made));
         Status := Write_Ok;
      else
         Path := Ada.Strings.Unbounded.Null_Unbounded_String;
         Status := Not_Writable;
      end if;
   end Make_Private_Directory;

   overriding procedure Remove_Tree
     (Host   : Native_Filesystem;
      Path   : String;
      Status : out Remove_Status)
   is
      pragma Unreferenced (Host);
      use type Interfaces.C.int;
      function Remove_Directory_Tree (Name : Interfaces.C.char_array)
        return Interfaces.C.int
        with Import, Convention => C, External_Name => "landin_remove_tree";
      Result : constant Interfaces.C.int :=
        Remove_Directory_Tree (Interfaces.C.To_C (Path));
   begin
      Status := (if Result = 1 then Removed
                 elsif Result = 0 then Already_Absent
                 else Not_Removable);
   end Remove_Tree;

   overriding procedure Get_Removal_Failure_Reason
     (Host : Native_Filesystem;
      Reason : in out Ada.Strings.Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host);
      function Last_Reason return Interfaces.C.Strings.chars_ptr
        with Import, Convention => C,
             External_Name => "landin_remove_tree_reason";
   begin
      Reason := Unbounded.To_Unbounded_String
        (Interfaces.C.Strings.Value (Last_Reason));
   end Get_Removal_Failure_Reason;

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
