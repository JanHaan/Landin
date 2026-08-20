with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;

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

      Stream_IO.Open (File, Stream_IO.In_File, Path);

      loop
         declare
            Buffer : Ada.Streams.Stream_Element_Array (1 .. Chunk_Size);
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            Stream_IO.Read (File, Buffer, Last);
            exit when Last < Buffer'First;

            for Index in Buffer'First .. Last loop
               Unbounded.Append
                 (Content, Character'Val (Natural (Buffer (Index))));
            end loop;

            exit when Last < Buffer'Last;
         end;
      end loop;

      Stream_IO.Close (File);
      Status := Read_Ok;

   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
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
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Status := Not_Writable;
   end Write_File;

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

      package Sorting is new Path_Vectors.Generic_Sorting ("<" => "<");

      Search : Directories.Search_Type;
      Item   : Directories.Directory_Entry_Type;
   begin
      Entries := Path_Vectors.Empty_Vector;

      if not Directories.Exists (Path) then
         Status := Directory_Not_Found;
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
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         Status := Directory_Not_Found;
   end List_Directory;

end Landin.Platform.Native;
