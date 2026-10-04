with Ada.Strings.Fixed;

package body Landin.Platform.Overlays is

   package Unbounded renames Ada.Strings.Unbounded;

   --  The text before a held path's last '/', and the text after it.  A
   --  path with no '/' is in no directory an overlay can list.
   function Directory_Of (Path : String) return String;
   function Entry_Of (Path : String) return String;

   function Directory_Of (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      return (if Slash = 0 then "" else Path (Path'First .. Slash - 1));
   end Directory_Of;

   function Entry_Of (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      return Path (Slash + 1 .. Path'Last);
   end Entry_Of;

   procedure Hold (Host : in out Overlay; Path : String; Content : String)
   is
   begin
      Host.Held.Include (Path, Content);
   end Hold;

   procedure Release (Host : in out Overlay; Path : String) is
   begin
      Host.Held.Exclude (Path);
   end Release;

   function Holds (Host : Overlay; Path : String) return Boolean
     is (Host.Held.Contains (Path));

   overriding function Exists
     (Host : Overlay; Path : String) return Boolean
     is (Host.Held.Contains (Path) or else Host.Under.Exists (Path));

   overriding function Working_Directory (Host : Overlay) return String
     is (Host.Under.Working_Directory);

   overriding function Paths_Overlap
     (Host : Overlay; Left, Right : String) return Boolean
     is (Left = Right or else Host.Under.Paths_Overlap (Left, Right));

   overriding function Paths_Overlap_Any
     (Host : Overlay; Left : String; Rights : Path_List) return Boolean
   is
   begin
      for Right of Rights loop
         if Left = Right then
            return True;
         end if;
      end loop;
      return Host.Under.Paths_Overlap_Any (Left, Rights);
   end Paths_Overlap_Any;

   overriding function Same_File
     (Host : Overlay; Left, Right : String) return Boolean
     is (Left = Right or else Host.Under.Same_File (Left, Right));

   overriding function Existing_File_Key
     (Host : Overlay; Path : String) return String
     is (Host.Under.Existing_File_Key (Path));

   overriding function Identity_Of
     (Host : Overlay; Path : String) return File_Identity
     is (if Host.Held.Contains (Path) then (others => <>)
         else Host.Under.Identity_Of (Path));

   overriding function Is_Directory
     (Host : Overlay; Path : String) return Boolean
     is (not Host.Held.Contains (Path)
         and then Host.Under.Is_Directory (Path));

   overriding procedure Read_File
     (Host    : Overlay;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Read_Status)
   is
      Found : constant Content_Maps.Cursor := Host.Held.Find (Path);
   begin
      if Content_Maps.Has_Element (Found) then
         Content := Unbounded.To_Unbounded_String
           (Content_Maps.Element (Found));
         Status := Read_Ok;
      else
         Host.Under.Read_File (Path, Content, Status);
      end if;
   end Read_File;

   overriding procedure Write_File
     (Host    : Overlay;
      Path    : String;
      Content : String;
      Status  : out Write_Status)
   is
      pragma Unreferenced (Host, Path, Content);
   begin
      Status := Not_Writable;
   end Write_File;

   overriding procedure Replace_File
     (Host    : Overlay;
      Path    : String;
      Content : String;
      Status  : out Write_Status)
   is
      pragma Unreferenced (Host, Path, Content);
   begin
      Status := Not_Writable;
   end Replace_File;

   overriding procedure Remove_File
     (Host   : Overlay;
      Path   : String;
      Status : out Remove_Status)
   is
      pragma Unreferenced (Host, Path);
   begin
      Status := Not_Removable;
   end Remove_File;

   overriding procedure Move_File
     (Host   : Overlay;
      From, To : String;
      Status : out Move_Status)
   is
      pragma Unreferenced (Host, From, To);
   begin
      Status := Not_Movable;
   end Move_File;

   overriding procedure Lock_Output
     (Host : Overlay; Path : String; Handle : out Integer)
   is
      pragma Unreferenced (Host, Path);
   begin
      Handle := -1;
   end Lock_Output;

   overriding procedure Unlock_Output
     (Host : Overlay; Handle : Integer)
   is
      pragma Unreferenced (Host, Handle);
   begin
      null;
   end Unlock_Output;

   --  The host's listing with every held entry of the same directory
   --  merged into its sorted place, once.
   overriding procedure List_Directory
     (Host    : Overlay;
      Path    : String;
      Entries : out Path_List;
      Status  : out List_Status)
   is
      Directory : constant String :=
        (if Path'Length > 1 and then Path (Path'Last) = '/'
         then Path (Path'First .. Path'Last - 1) else Path);
      Listed : Path_List;
      Next   : Positive := 1;
   begin
      Host.Under.List_Directory (Path, Listed, Status);
      Entries.Clear;
      if Status /= List_Ok then
         return;
      end if;
      for Position in Host.Held.Iterate loop
         declare
            Held_Path : constant String := Content_Maps.Key (Position);
         begin
            if Directory_Of (Held_Path) = Directory then
               declare
                  Name : constant String := Entry_Of (Held_Path);
               begin
                  while Next <= Natural (Listed.Length)
                    and then Listed.Element (Next) < Name
                  loop
                     Entries.Append (Listed.Element (Next));
                     Next := Next + 1;
                  end loop;
                  if Next <= Natural (Listed.Length)
                    and then Listed.Element (Next) = Name
                  then
                     Next := Next + 1;
                  end if;
                  Entries.Append (Name);
               end;
            end if;
         end;
      end loop;
      while Next <= Natural (Listed.Length) loop
         Entries.Append (Listed.Element (Next));
         Next := Next + 1;
      end loop;
   end List_Directory;

end Landin.Platform.Overlays;
