with Ada.Strings.Fixed;

package body Landin.Platform.Overlays is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Interfaces.Unsigned_64;

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

   function Same_Object (Left, Right : File_Identity) return Boolean
     is (Left.Valid and then Right.Valid
         and then Left.Device = Right.Device
         and then Left.Inode = Right.Inode);

   --  Path with a '/' after it, which every path beneath it begins with.
   function Beneath (Path : String) return String
     is (if Path'Length > 0 and then Path (Path'Last) = '/' then Path
         else Path & "/");

   function Starts (Text, Prefix : String) return Boolean
     is (Text'Length >= Prefix'Length
         and then Text (Text'First .. Text'First + Prefix'Length - 1)
           = Prefix);

   --  Whether a held path lies beneath Path, which makes Path a directory
   --  the host need not have.
   function Implied_Directory (Host : Overlay; Path : String) return Boolean;

   function Implied_Directory (Host : Overlay; Path : String) return Boolean
   is
      Prefix : constant String := Beneath (Path);
      Found  : constant Content_Maps.Cursor :=
        (if Path = "" then Content_Maps.No_Element
         else Host.Held.Ceiling (Prefix));
   begin
      return Content_Maps.Has_Element (Found)
        and then Content_Maps.Key (Found)'Length > Prefix'Length
        and then Starts (Content_Maps.Key (Found), Prefix);
   end Implied_Directory;

   function Held_As (Host : Overlay; Path : String) return String is
   begin
      if Host.Held.Contains (Path) then
         return Path;
      elsif Host.Held.Is_Empty or else Path = "" then
         return "";
      end if;
      declare
         File      : constant File_Identity :=
           Host.Under.Existing_Identity (Path);
         Directory : constant String := Directory_Of (Path);
         Name      : constant String := Entry_Of (Path);
         Asked     : Boolean := False;
         Within    : File_Identity;
      begin
         for Position in Host.Held.Iterate loop
            declare
               Held_Path : constant String := Content_Maps.Key (Position);
               Held_In   : constant String := Directory_Of (Held_Path);
            begin
               if File.Valid
                 and then Same_Object
                   (File, Host.Under.Existing_Identity (Held_Path))
               then
                  return Held_Path;
               elsif Directory /= "" and then Held_In /= ""
                 and then Held_In /= Directory
                 and then Entry_Of (Held_Path) = Name
               then
                  --  A buffer the host may not have yet, in a directory
                  --  the loader spelled another way.
                  if not Asked then
                     Within := Host.Under.Existing_Identity (Directory);
                     Asked := True;
                  end if;
                  if Same_Object
                    (Within, Host.Under.Existing_Identity (Held_In))
                  then
                     return Held_Path;
                  end if;
               end if;
            end;
         end loop;
      end;
      return "";
   end Held_As;

   overriding function Exists
     (Host : Overlay; Path : String) return Boolean
     is (Host.Held.Contains (Path) or else Host.Under.Exists (Path)
         or else Implied_Directory (Host, Path)
         or else Held_As (Host, Path) /= "");

   overriding function Working_Directory (Host : Overlay) return String
     is (Host.Under.Working_Directory);

   overriding function Executable_Directory (Host : Overlay) return String
     is (Host.Under.Executable_Directory);

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

   overriding function Observe_Identity
     (Host : Overlay; Path : String) return Identity_Observation
     is (if Host.Held.Contains (Path) then
           (Identity => (others => <>), Status => Read_Ok,
            Parent_Resolved => False)
         else Host.Under.Observe_Identity (Path));

   overriding function Identity_Of
     (Host : Overlay; Path : String) return File_Identity
     is (if Host.Held.Contains (Path) then (others => <>)
         else Host.Under.Identity_Of (Path));
   overriding function Existing_Identity
     (Host : Overlay; Path : String) return File_Identity
     is (if Host.Held.Contains (Path) then (others => <>)
         else Host.Under.Existing_Identity (Path));

   overriding function Is_Directory
     (Host : Overlay; Path : String) return Boolean
     is (not Host.Held.Contains (Path)
         and then (Host.Under.Is_Directory (Path)
                   or else Implied_Directory (Host, Path)));

   overriding function Is_Link
     (Host : Overlay; Path : String) return Boolean
     is (not Host.Held.Contains (Path) and then Host.Under.Is_Link (Path));

   overriding procedure Read_File
     (Host    : Overlay;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Read_Status)
   is
      Found : Content_Maps.Cursor := Host.Held.Find (Path);
   begin
      if not Content_Maps.Has_Element (Found) then
         declare
            Other : constant String := Held_As (Host, Path);
         begin
            if Other /= "" then
               Found := Host.Held.Find (Other);
            end if;
         end;
      end if;
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

   overriding procedure Write_File
     (Host    : Overlay;
      Path    : String;
      Content : String;
      Status  : out Write_Status;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host, Path, Content);
   begin
      Status := Not_Writable;
      Reason := Unbounded.To_Unbounded_String ("the overlay is read-only");
   end Write_File;

   overriding procedure Replace_File
     (Host    : Overlay;
      Path    : String;
      Content : String;
      Status  : out Write_Status;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host, Path, Content);
   begin
      Status := Not_Writable;
      Reason := Unbounded.To_Unbounded_String
        ("an editor's buffer is not written to the file it shows");
   end Replace_File;

   overriding procedure Open_Publication
     (Host : Overlay; Path : String; Delete_Only : Boolean; Root : String;
      Handle : out Publication_Handle;
      Stage : out Unbounded.Unbounded_String; Status : out Write_Status;
      Reason : out Unbounded.Unbounded_String;
      Require_Absent : Boolean := False;
      Directory : Boolean := False)
   is
      pragma Unreferenced
        (Host, Path, Delete_Only, Root, Require_Absent, Directory);
   begin
      Handle := No_Publication;
      Stage := Unbounded.Null_Unbounded_String;
      Status := Not_Writable;
      Reason := Unbounded.To_Unbounded_String
        ("an editor overlay is read-only");
   end Open_Publication;

   overriding procedure Advance_Publication
     (Host : Overlay; Handle : Publication_Handle;
      Action : Publication_Action; Protected_Paths : Path_List;
      Protected_Identities : Identity_List; Status : out Write_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced
        (Host, Handle, Action, Protected_Paths, Protected_Identities);
   begin
      Status := Not_Writable;
      Reason := Unbounded.To_Unbounded_String
        ("an editor overlay is read-only");
   end Advance_Publication;

   overriding function Cancellation_Requested (Host : Overlay) return Boolean
     is (Host.Under.Cancellation_Requested);

   overriding procedure Read_Snapshot
     (Host : Overlay; Path : String;
      Content : out Unbounded.Unbounded_String;
      Identity : out File_Identity; Status : out Read_Status) is
   begin
      if Held_As (Host, Path) /= "" then
         Read_File (Host, Path, Content, Status);
         Identity := (others => <>);
      else
         Read_Snapshot (Host.Under.all, Path, Content, Identity, Status);
      end if;
   end Read_Snapshot;

   overriding procedure Read_For_Update
     (Host : Overlay; Path : String;
      Content : out Unbounded.Unbounded_String;
      Lease : out Update_Handle; Status : out Read_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host, Path);
   begin
      Content := Unbounded.Null_Unbounded_String;
      Lease := No_Update;
      Status := Not_Readable;
      Reason := Unbounded.To_Unbounded_String
        ("an editor overlay is read-only");
   end Read_For_Update;

   overriding procedure Replace_Update
     (Host : Overlay; Lease : Update_Handle; Content : String;
      Status : out Write_Status; Reason : out Unbounded.Unbounded_String)
   is
      pragma Unreferenced (Host, Lease, Content);
   begin
      Status := Not_Writable;
      Reason := Unbounded.To_Unbounded_String
        ("an editor overlay is read-only");
   end Replace_Update;

   overriding function Update_Identity
     (Host : Overlay; Lease : Update_Handle) return File_Identity
   is
      pragma Unreferenced (Host, Lease);
   begin
      return (others => <>);
   end Update_Identity;

   overriding procedure Close_Update (Host : Overlay; Lease : Update_Handle) is
      pragma Unreferenced (Host, Lease);
   begin
      null;
   end Close_Update;

   overriding procedure Remove_File
     (Host   : Overlay;
      Path   : String;
      Status : out Remove_Status)
   is
      pragma Unreferenced (Host, Path);
   begin
      Status := Not_Removable;
   end Remove_File;

   overriding procedure Make_Directory
     (Host   : Overlay;
      Path   : String;
      Status : out Write_Status)
   is
      pragma Unreferenced (Host, Path);
   begin
      Status := Not_Writable;
   end Make_Directory;

   overriding procedure Make_Private_Directory
     (Host   : Overlay;
      Prefix : String;
      Path   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Write_Status)
   is
      pragma Unreferenced (Host, Prefix);
   begin
      Path := Ada.Strings.Unbounded.Null_Unbounded_String;
      Status := Not_Writable;
   end Make_Private_Directory;

   overriding procedure Remove_Tree
     (Host   : Overlay;
      Path   : String;
      Status : out Remove_Status)
   is
      pragma Unreferenced (Host, Path);
   begin
      Status := Not_Removable;
   end Remove_Tree;

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
   --  merged into its sorted place, once: a held file in it, and the first
   --  name of a held path further beneath it, which is a directory.  A
   --  directory only held paths make is listed from them alone.
   overriding procedure List_Directory
     (Host    : Overlay;
      Path    : String;
      Entries : out Path_List;
      Status  : out List_Status)
   is
      Directory : constant String :=
        (if Path'Length > 1 and then Path (Path'Last) = '/'
         then Path (Path'First .. Path'Last - 1) else Path);
      Prefix : constant String := Beneath (Directory);
      Listed : Path_List;
      Names  : Name_Sets.Set;
      Next   : Positive := 1;
      Asked  : Boolean := False;
      Within : File_Identity;
   begin
      Host.Under.List_Directory (Path, Listed, Status);
      Entries.Clear;
      for Position in Host.Held.Iterate loop
         declare
            Held_Path : constant String := Content_Maps.Key (Position);
            Held_In   : constant String := Directory_Of (Held_Path);
         begin
            if Directory /= "" and then Starts (Held_Path, Prefix)
              and then Held_Path'Length > Prefix'Length
            then
               declare
                  Rest  : constant String :=
                    Held_Path (Held_Path'First + Prefix'Length
                               .. Held_Path'Last);
                  Slash : constant Natural :=
                    Ada.Strings.Fixed.Index (Rest, "/");
               begin
                  Names.Include
                    (if Slash = 0 then Rest
                     else Rest (Rest'First .. Slash - 1));
               end;
            elsif Status = List_Ok and then Held_In /= ""
              and then Directory /= ""
            then
               --  The same directory under another spelling.
               if not Asked then
                  Within := Host.Under.Existing_Identity (Directory);
                  Asked := True;
               end if;
               if Same_Object
                 (Within, Host.Under.Existing_Identity (Held_In))
               then
                  Names.Include (Entry_Of (Held_Path));
               end if;
            end if;
         end;
      end loop;
      if Status /= List_Ok then
         --  Only a directory the host does not have is made of what is
         --  held; one it has and cannot list stays unlistable.
         if Names.Is_Empty or else Host.Under.Exists (Directory) then
            return;
         end if;
         Listed.Clear;
         Status := List_Ok;
      end if;
      for Name of Names loop
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
      end loop;
      while Next <= Natural (Listed.Length) loop
         Entries.Append (Listed.Element (Next));
         Next := Next + 1;
      end loop;
   end List_Directory;

end Landin.Platform.Overlays;
