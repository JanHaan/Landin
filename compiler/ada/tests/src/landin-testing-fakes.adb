with Ada.Strings.Fixed;
with Landin.Platform.Native;
with Landin.Targets.Firmware;
with Landin.Targets.Selection;
with Ada.Unchecked_Deallocation;

package body Landin.Testing.Fakes is

   use type Landin.Platform.File_Identity;
   use type Landin.Platform.Update_Handle;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Platform.Termination;
   use type Interfaces.Unsigned_64;

   overriding procedure Finalize (Owner : in out Store_Owner) is
      procedure Free is new Ada.Unchecked_Deallocation (Store, Store_Access);
   begin
      Free (Owner.Data);
   end Finalize;

   overriding procedure Finalize (Owner : in out Recorder_Owner) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Recorder, Recorder_Access);
   begin
      Free (Owner.Data);
   end Finalize;

   function Directory_Path (Path : String) return String;

   function Directory_Path (Path : String) return String is
      Last : Natural := Path'Last;
   begin
      while Last > Path'First and then Path (Last) = '/' loop
         Last := Last - 1;
      end loop;
      return Path (Path'First .. Last);
   end Directory_Path;

   function Find
     (Host : Fake_Filesystem; Path : String) return Natural;

   function Find
     (Host : Fake_Filesystem; Path : String) return Natural
   is
   begin
      for Index in 1 .. Natural (Host.Writes.Data.Files.Length) loop
         declare
            Item : constant File_Entry :=
              Host.Writes.Data.Files.Element (Index);
            Stored : constant String := Unbounded.To_String (Item.Path);
         begin
            if Stored = Path
              or else (Item.Kind in A_Directory | An_Unlistable_Directory
                       and then Stored = Directory_Path (Path))
            then
               return Index;
            end if;
         end;
      end loop;
      return 0;
   end Find;

   function Resolve_Find
     (Host : Fake_Filesystem; Path : String) return Natural;
   function Resolve_Find
     (Host : Fake_Filesystem; Path : String) return Natural
   is
      Name : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (Path);
      Index : Natural;
   begin
      for Depth in 1 .. 40 loop
         Index := Find (Host, Unbounded.To_String (Name));
         if Index = 0 then
            return 0;
         elsif Host.Writes.Data.Files (Index).Kind /= A_Link then
            return Index;
         end if;
         declare
            Target : constant String := Unbounded.To_String
              (Host.Writes.Data.Files (Index).Content);
            Current : constant String := Unbounded.To_String (Name);
            Slash : constant Natural := Ada.Strings.Fixed.Index
              (Current, "/", Ada.Strings.Backward);
         begin
            Name := Unbounded.To_Unbounded_String
              ((if Target /= "" and then Target (Target'First) = '/'
                then "" else Current (Current'First .. Slash)) & Target);
         end;
      end loop;
      return 0;
   end Resolve_Find;

   procedure Add
     (Host : in out Fake_Filesystem;
      Path : String;
      Text : String;
      Kind : Entry_Kind);

   procedure Add
     (Host : in out Fake_Filesystem;
      Path : String;
      Text : String;
      Kind : Entry_Kind)
   is
      Existing : constant Natural := Find (Host, Path);
      Item     : File_Entry :=
        (Path    => Unbounded.To_Unbounded_String (Path),
         Content => Unbounded.To_Unbounded_String (Text),
         Kind    => Kind,
         Identity => 0);
   begin
      Item.Identity := Host.Writes.Data.Next_Identity;
      Host.Writes.Data.Next_Identity :=
        Host.Writes.Data.Next_Identity + 1;
      if Existing = 0 then
         Host.Writes.Data.Files.Append (Item);
      else
         Host.Writes.Data.Files.Replace_Element (Existing, Item);
      end if;
   end Add;

   procedure Add_File
     (Host : in out Fake_Filesystem; Path : String; Content : String)
   is
   begin
      Add (Host, Path, Content, A_File);
   end Add_File;

   procedure Add_Hard_Link
     (Host : in out Fake_Filesystem; Path, Target : String)
   is
      Index : constant Natural := Resolve_Find (Host, Target);
      Item : File_Entry;
   begin
      if Index = 0 or else Find (Host, Path) /= 0 then
         raise Program_Error with "fake hard link needs an existing target";
      end if;
      Item := Host.Writes.Data.Files (Index);
      Item.Path := Unbounded.To_Unbounded_String (Path);
      Host.Writes.Data.Files.Append (Item);
   end Add_Hard_Link;

   procedure Add_Symbolic_Link
     (Host : in out Fake_Filesystem; Path, Target : String) is
   begin
      Add (Host, Path, Target, A_Link);
   end Add_Symbolic_Link;

   procedure Replace_On_Publication
     (Host : in out Fake_Filesystem;
      Action : Landin.Platform.Publication_Action;
      Path, Content : String; As_Link : Boolean := False) is
   begin
      Host.Writes.Data.Mutation_Armed := True;
      Host.Writes.Data.Mutation_Action := Action;
      Host.Writes.Data.Mutation_File :=
        (Path => Unbounded.To_Unbounded_String (Path),
         Content => Unbounded.To_Unbounded_String (Content),
         Kind => (if As_Link then A_Link else A_File), Identity => 0);
   end Replace_On_Publication;

   procedure Appear_Before_Publication
     (Host : in out Fake_Filesystem; Path, Target : String) is
   begin
      Host.Writes.Data.Appearance_Armed := True;
      Host.Writes.Data.Appearance_Before_Open := True;
      Host.Writes.Data.Appearance_Path :=
        Unbounded.To_Unbounded_String (Path);
      Host.Writes.Data.Appearance_Target :=
        Unbounded.To_Unbounded_String (Target);
   end Appear_Before_Publication;

   procedure Appear_On_Publication
     (Host : in out Fake_Filesystem;
      Action : Landin.Platform.Publication_Action; Path, Target : String) is
   begin
      Appear_Before_Publication (Host, Path, Target);
      Host.Writes.Data.Appearance_Before_Open := False;
      Host.Writes.Data.Appearance_Action := Action;
   end Appear_On_Publication;

   procedure Add_Directory (Host : in out Fake_Filesystem; Path : String) is
   begin
      Add (Host, Directory_Path (Path), "", A_Directory);
   end Add_Directory;

   procedure Add_Unlistable_Directory
     (Host : in out Fake_Filesystem; Path : String) is
   begin
      Add (Host, Directory_Path (Path), "", An_Unlistable_Directory);
   end Add_Unlistable_Directory;

   procedure Add_Unreadable (Host : in out Fake_Filesystem; Path : String) is
   begin
      Add (Host, Path, "", An_Unreadable_File);
   end Add_Unreadable;

   function Written (Host : Fake_Filesystem; Path : String) return String is
   begin
      for Item of Host.Writes.Data.Items loop
         if Unbounded.To_String (Item.Path) = Path then
            return Unbounded.To_String (Item.Content);
         end if;
      end loop;
      return "";
   end Written;

   function Write_Count (Host : Fake_Filesystem) return Natural
     is (Host.Writes.Data.Write_Attempts);

   function List_Count
     (Host : Fake_Filesystem; Path : String) return Natural
   is
   begin
      for Call of Host.Writes.Data.List_Calls loop
         if Unbounded.To_String (Call.Path) = Path then
            return Call.Count;
         end if;
      end loop;
      return 0;
   end List_Count;

   overriding function Exists
     (Host : Fake_Filesystem; Path : String) return Boolean
     is (Resolve_Find (Host, Path) /= 0);

   procedure Add_Alias
     (Host : in out Fake_Filesystem; Left, Right : String) is
   begin
      Host.Aliases.Append (Left);
      Host.Aliases.Append (Right);
   end Add_Alias;

   overriding function Same_File
     (Host : Fake_Filesystem; Left, Right : String) return Boolean
   is
   begin
      Host.Writes.Data.Identity_Comparisons :=
        Host.Writes.Data.Identity_Comparisons + 1;
      return Host.Exists (Left) and then Host.Exists (Right)
        and then Host.Paths_Overlap (Left, Right);
   end Same_File;

   overriding function Existing_Identity
     (Host : Fake_Filesystem; Path : String)
      return Landin.Platform.File_Identity
   is
      Index : constant Natural := Resolve_Find (Host, Path);
   begin
      if Host.Raising_Identities.Contains (Path) then
         raise Program_Error with "a fake identity injected an exception";
      end if;
      if Index = 0 then
         return (others => <>);
      end if;
      --  Explicit aliases are only pairwise in this fake. Defer those
      --  names to Same_File rather than inventing a transitive key.
      for Alias_Path of Host.Aliases loop
         if Alias_Path = Path
           or else (Host.Is_Directory (Path)
                    and then Directory_Path (Alias_Path)
                      = Directory_Path (Path))
         then
            return (others => <>);
         end if;
      end loop;
      return (Valid => True, Device => 1,
              Inode => Host.Writes.Data.Files (Index).Identity);
   end Existing_Identity;

   function Same_File_Count (Host : Fake_Filesystem) return Natural
     is (Host.Writes.Data.Identity_Comparisons);

   procedure Set_Executable_Directory
     (Host : in out Fake_Filesystem; Directory : String) is
   begin
      Host.Executable := Unbounded.To_Unbounded_String (Directory);
   end Set_Executable_Directory;

   procedure Add_Firmware_Library (Host : in out Fake_Filesystem) is
      --  Deliberate real-host read of the checkout's library, from the
      --  test program's working directory, compiler/ada.
      Real : Landin.Platform.Native.Native_Filesystem;
      Library : constant String := "/opt/landin/lib/landin";
      Text : Ada.Strings.Unbounded.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      procedure Add_Reference (Module : String);

      procedure Add_Reference (Module : String) is
         Separator : constant Natural := Ada.Strings.Fixed.Index
           (Module, "/", Ada.Strings.Backward);
      begin
         if Module /= "" then
            Host.Add_Directory
              (Library & "/" & Module (Module'First .. Separator - 1));
            Host.Add_Directory (Library & "/" & Module);
            for Which in 1 .. 2 loop
               declare
                  File : constant String := Module & "/"
                    & (if Which = 1 then "interrupts.ldn"
                       else "memory.ldn");
               begin
                  Real.Read_File ("../../" & File, Text, Status);
                  if Status /= Landin.Platform.Read_Ok then
                     raise Program_Error with "the checkout's reference"
                       & " description cannot be read: " & File;
                  end if;
                  Host.Add_File
                    (Library & "/" & File,
                     Ada.Strings.Unbounded.To_String (Text));
               end;
            end loop;
         end if;
      end Add_Reference;
   begin
      Host.Set_Executable_Directory ("/opt/landin/bin");
      Host.Add_Directory (Library);
      Host.Add_Directory (Library & "/platform");
      --  Deliberate real-host reference reads, including the second Xtensa
      --  level: fake filesystem cases exercise both unconditional profiles.
      for Target in 1 .. Landin.Targets.Selection.Described_Count loop
         Add_Reference (Landin.Targets.Firmware.Reference_Module
           (Landin.Targets.Selection.Described_At (Target)));
      end loop;
      Add_Reference (Landin.Targets.Firmware.Reference_Module
        (Landin.Targets.Xtensa, "xtensa-esp32s3"));
   end Add_Firmware_Library;

   overriding function Executable_Directory
     (Host : Fake_Filesystem) return String
     is (Unbounded.To_String (Host.Executable));

   overriding function Existing_File_Key
     (Host : Fake_Filesystem; Path : String) return String
   is
      pragma Unreferenced (Host, Path);
   begin
      --  Declared alias pairs do not provide a complete equivalence class.
      return "";
   end Existing_File_Key;

   procedure Appear_On_Identity_Observation
     (Host : in out Fake_Filesystem; Path, Target : String) is
   begin
      Host.Writes.Data.Observed_Path := Unbounded.To_Unbounded_String (Path);
      Host.Writes.Data.Observed_Target :=
        Unbounded.To_Unbounded_String (Target);
      Host.Writes.Data.Observations := 0;
   end Appear_On_Identity_Observation;

   procedure Set_Identity_Uncertain
     (Host : in out Fake_Filesystem; Path : String) is
   begin
      Host.Uncertain_Identities.Append (Path);
   end Set_Identity_Uncertain;

   procedure Raise_On_Identity
     (Host : in out Fake_Filesystem; Path : String) is
   begin
      Host.Raising_Identities.Append (Path);
   end Raise_On_Identity;

   overriding function Observe_Identity
     (Host : Fake_Filesystem; Path : String)
      return Landin.Platform.Identity_Observation
   is
      Found : Landin.Platform.File_Identity;
      Slash : constant Natural := Ada.Strings.Fixed.Index
        (Path, "/", Ada.Strings.Backward);
      Parent : constant String :=
        (if Slash = 0 then Host.Working_Directory
         elsif Slash = Path'First then "/"
         else Path (Path'First .. Slash - 1));
   begin
      if Path = "" then
         return (others => <>);
      end if;
      if Path = Unbounded.To_String (Host.Writes.Data.Observed_Path) then
         Host.Writes.Data.Observations := Host.Writes.Data.Observations + 1;
         if Host.Writes.Data.Observations = 2 then
            declare
               Index : constant Natural := Resolve_Find
                 (Host,
                  Unbounded.To_String (Host.Writes.Data.Observed_Target));
               Item : File_Entry := Host.Writes.Data.Files (Index);
            begin
               Item.Path := Unbounded.To_Unbounded_String (Path);
               Host.Writes.Data.Files.Append (Item);
            end;
         end if;
      end if;
      Found := Identity_Of (Host, Path);
      if Host.Uncertain_Identities.Contains (Path) then
         return (others => <>);
      end if;
      if not Found.Valid and then Host.Is_Link (Path) then
         return (others => <>);
      end if;
      declare
         Ancestor : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String (Parent);
      begin
         --  A missing leaf below an occupied non-directory or dangling
         --  ancestor is uncertain, just as native ENOTDIR or failed lookup.
         loop
            declare
               Name : constant String := Unbounded.To_String (Ancestor);
               Cut : constant Natural := Ada.Strings.Fixed.Index
                 (Name, "/", Ada.Strings.Backward);
            begin
               if Host.Uncertain_Identities.Contains (Name)
                 or else ((Host.Exists (Name) or else Host.Is_Link (Name))
                          and then not Host.Is_Directory (Name))
               then
                  return (others => <>);
               end if;
               exit when Name in "" | "/" | "." | Host.Working_Directory;
               Ancestor := Unbounded.To_Unbounded_String
                 (if Cut = 0 then Host.Working_Directory
                  elsif Cut = Name'First then "/"
                  else Name (Name'First .. Cut - 1));
            end;
         end loop;
      end;
      return (Identity => Found,
              Status => (if Found.Valid then Landin.Platform.Read_Ok
                         else Landin.Platform.Not_Found),
              Parent_Resolved => not Found.Valid
                and then (Parent in "/" | "." | Host.Working_Directory
                          or else Host.Is_Directory (Parent)));
   end Observe_Identity;

   overriding function Identity_Of
     (Host : Fake_Filesystem; Path : String)
      return Landin.Platform.File_Identity
   is
      Index : constant Natural := Resolve_Find (Host, Path);
   begin
      if Index = 0 then
         return (others => <>);
      end if;
      return (Device => 1,
              Inode => Host.Writes.Data.Files (Index).Identity,
              Valid => True);
   end Identity_Of;

   function Output_Locked (Host : Fake_Filesystem) return Boolean
     is (Host.Writes.Data.Output_Is_Locked);

   overriding function Paths_Overlap
     (Host : Fake_Filesystem; Left, Right : String) return Boolean is
   begin
      if (Identity_Of (Host, Left).Valid
          and then Identity_Of (Host, Right).Valid
          and then Identity_Of (Host, Left) = Identity_Of (Host, Right))
        or else Left = Right
        or else (Directory_Path (Left) = Directory_Path (Right)
                 and then Host.Is_Directory (Left)
                 and then Host.Is_Directory (Right))
      then
         return True;
      end if;
      for Pair in 1 .. Natural (Host.Aliases.Length) / 2 loop
         if (Host.Aliases (Pair * 2 - 1) = Left
             and then Host.Aliases (Pair * 2) = Right)
           or else (Host.Aliases (Pair * 2 - 1) = Right
                    and then Host.Aliases (Pair * 2) = Left)
         then
            return True;
         end if;
      end loop;
      return False;
   end Paths_Overlap;

   overriding function Paths_Overlap_Any
     (Host : Fake_Filesystem; Left : String;
      Rights : Landin.Platform.Path_List) return Boolean
   is
   begin
      for Right of Rights loop
         if Host.Paths_Overlap (Left, Right) then
            return True;
         end if;
      end loop;
      return False;
   end Paths_Overlap_Any;

   overriding function Is_Directory
     (Host : Fake_Filesystem; Path : String) return Boolean
   is
      Index : constant Natural := Resolve_Find (Host, Path);
   begin
      return Index /= 0
        and then Host.Writes.Data.Files.Element (Index).Kind
          in A_Directory | An_Unlistable_Directory;
   end Is_Directory;

   overriding function Is_Link
     (Host : Fake_Filesystem; Path : String) return Boolean
     is (Host.Links.Contains (Path)
         or else (Find (Host, Path) /= 0
                  and then Host.Writes.Data.Files
                    (Find (Host, Path)).Kind = A_Link));

   procedure Add_Link (Host : in out Fake_Filesystem; Path : String) is
   begin
      Host.Links.Append (Path);
   end Add_Link;

   procedure Raise_On_Read
     (Host : in out Fake_Filesystem;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity) is
   begin
      Host.Writes.Data.Raises := True;
      Host.Writes.Data.Reads_Before_Raise := 0;
      Host.Writes.Data.Read_Exception := Reason;
   end Raise_On_Read;

   procedure Raise_On_Read_After
     (Host : in out Fake_Filesystem; Reads : Natural;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity) is
   begin
      Host.Writes.Data.Raises := True;
      Host.Writes.Data.Reads_Before_Raise := Reads;
      Host.Writes.Data.Read_Exception := Reason;
   end Raise_On_Read_After;

   function Stage_Path_Usable
     (Host : Fake_Filesystem; Path : String; Claimed : out Boolean)
      return Boolean;
   function Stage_Path_Usable
     (Host : Fake_Filesystem; Path : String; Claimed : out Boolean)
      return Boolean
   is
      Active : Boolean := False;
   begin
      Claimed := False;
      for Item of Host.Writes.Data.Publications loop
         declare
            Stage : constant String := Unbounded.To_String (Item.Stage);
         begin
            if Path = Stage
              or else (Path'Length > Stage'Length
                and then Path (Path'First .. Path'First + Stage'Length)
                  = Stage & "/")
            then
               Claimed := True;
               if not Item.Finished then
                  Active := True;
                  for Position in Path'First + Stage'Length .. Path'Last loop
                     if Path (Position) = '/' then
                        declare
                           Parent : constant String :=
                             Path (Path'First .. Position - 1);
                        begin
                           if Host.Is_Link (Parent)
                             or else not Host.Is_Directory (Parent)
                           then
                              return False;
                           end if;
                        end;
                     end if;
                  end loop;
               end if;
            end if;
         end;
      end loop;
      return not Claimed or else Active;
   end Stage_Path_Usable;

   overriding procedure Read_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Landin.Platform.Read_Status)
   is
      Index : constant Natural := Resolve_Find (Host, Path);
      Claimed : Boolean;
   begin
      Content := Unbounded.Null_Unbounded_String;
      if not Stage_Path_Usable (Host, Path, Claimed) then
         Status := Landin.Platform.Not_Readable;
         return;
      end if;

      if Host.Writes.Data.Raises then
         if Host.Writes.Data.Reads_Before_Raise > 0 then
            Host.Writes.Data.Reads_Before_Raise :=
              Host.Writes.Data.Reads_Before_Raise - 1;
         else
            Host.Writes.Data.Raises := False;
            Ada.Exceptions.Raise_Exception
              (Host.Writes.Data.Read_Exception,
               "a fake read injected an exception");
         end if;
      end if;

      if Index = 0 then
         Status := Landin.Platform.Not_Found;
         return;
      end if;

      case Host.Writes.Data.Files.Element (Index).Kind is
         when A_File =>
            Content := Host.Writes.Data.Files.Element (Index).Content;
            Status := Landin.Platform.Read_Ok;
         when A_Link | A_Directory | An_Unlistable_Directory |
              An_Unreadable_File =>
            Status := Landin.Platform.Not_Readable;
      end case;
   end Read_File;

   procedure Refuse_Writes (Host : in out Fake_Filesystem) is
   begin
      Host.Writes.Data.Refuses_Write := True;
   end Refuse_Writes;

   procedure Refuse_Staged_Write
     (Host : in out Fake_Filesystem; Public_Path : String) is
   begin
      Host.Writes.Data.Refused_Staged_Writes.Append (Public_Path);
   end Refuse_Staged_Write;

   overriding procedure Write_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status)
   is
      Existing : constant Natural := Resolve_Find (Host, Path);
      Entry_Value : File_Entry :=
        (Path    => Unbounded.To_Unbounded_String (Path),
         Content => Unbounded.To_Unbounded_String (Content),
         Kind    => A_File,
         Identity => 0);
      Claimed : Boolean;
   begin
      Entry_Value.Identity := Host.Writes.Data.Next_Identity;
      Host.Writes.Data.Next_Identity :=
        Host.Writes.Data.Next_Identity + 1;
      Host.Writes.Data.Write_Attempts := Host.Writes.Data.Write_Attempts + 1;
      for Reservation of Host.Writes.Data.Publications loop
         if not Reservation.Finished
           and then Unbounded.To_String (Reservation.Stage) = Path
           and then Host.Writes.Data.Refused_Staged_Writes.Contains
             (Unbounded.To_String (Reservation.Path))
         then
            Status := Landin.Platform.Not_Writable;
            return;
         end if;
      end loop;
      if not Stage_Path_Usable (Host, Path, Claimed)
        or else Host.Writes.Data.Refuses_Write
        or else (Host.Is_Link (Path)
                 and then Ada.Strings.Fixed.Index
                   (Path, "/.refine-publication/") /= 0)
        or else (Existing /= 0
                 and then Host.Writes.Data.Files (Existing).Kind
                   in A_Directory | An_Unlistable_Directory)
      then
         Status := Landin.Platform.Not_Writable;
         return;
      end if;

      if Existing = 0 then
         Host.Writes.Data.Files.Append (Entry_Value);
      else
         Entry_Value.Identity := Host.Writes.Data.Files (Existing).Identity;
         for Index in 1 .. Natural (Host.Writes.Data.Files.Length) loop
            declare
               Linked : File_Entry := Host.Writes.Data.Files (Index);
            begin
               if Linked.Identity = Entry_Value.Identity then
                  Linked.Content := Entry_Value.Content;
                  Host.Writes.Data.Files.Replace_Element (Index, Linked);
               end if;
            end;
         end loop;
      end if;
      Status := Landin.Platform.Write_Ok;
      for Index in 1 .. Natural (Host.Writes.Data.Items.Length) loop
         if Unbounded.To_String (Host.Writes.Data.Items (Index).Path) = Path
         then
            Host.Writes.Data.Items.Replace_Element (Index, Entry_Value);
            return;
         end if;
      end loop;
      Host.Writes.Data.Items.Append (Entry_Value);
   end Write_File;

   overriding procedure Write_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String)
   is
   begin
      Write_File (Fake_Filesystem'Class (Host), Path, Content, Status);
      Reason := Unbounded.Null_Unbounded_String;
      if Status /= Landin.Platform.Write_Ok then
         Reason := Unbounded.To_Unbounded_String
           ("the fake host refuses writes");
      end if;
   end Write_File;

   overriding procedure Replace_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status;
      Reason  : out Ada.Strings.Unbounded.Unbounded_String)
   is
   begin
      Reason := Unbounded.Null_Unbounded_String;
      if not Host.Exists (Path) then
         Status := Landin.Platform.Not_Writable;
         Reason := Unbounded.To_Unbounded_String ("cannot find it");
      else
         Host.Write_File (Path, Content, Status);
         if Status /= Landin.Platform.Write_Ok then
            Reason := Unbounded.To_Unbounded_String
              ("the fake host refuses writes");
         end if;
      end if;
   end Replace_File;

   procedure Refuse_Removals (Host : in out Fake_Filesystem) is
   begin
      Host.Writes.Data.Refuses_Removal := True;
   end Refuse_Removals;

   procedure Refuse_Removals
     (Host : in out Fake_Filesystem;
      From_Action : Landin.Platform.Publication_Action) is
   begin
      Host.Writes.Data.Removal_Refusal_Armed := True;
      Host.Writes.Data.Removal_Refusal_Action := From_Action;
   end Refuse_Removals;

   procedure Request_Cancellation (Host : in out Fake_Filesystem) is
   begin
      Host.Writes.Data.Cancelled := True;
   end Request_Cancellation;

   procedure Request_Cancellation
     (Host : in out Fake_Filesystem;
      At_Action : Landin.Platform.Publication_Action) is
   begin
      Host.Writes.Data.Cancel_Armed := True;
      Host.Writes.Data.Cancel_Action := At_Action;
   end Request_Cancellation;

   overriding function Cancellation_Requested
     (Host : Fake_Filesystem) return Boolean
     is (Host.Writes.Data.Cancelled);

   procedure Fail_Move (Host : in out Fake_Filesystem; At_Move : Positive) is
   begin
      Host.Writes.Data.Fails_Move := True;
      Host.Writes.Data.Moves_Before_Failure := At_Move - 1;
   end Fail_Move;

   function Snapshot_Below
     (Host : Fake_Filesystem; Root : String) return File_Vectors.Vector;
   function Snapshot_Below
     (Host : Fake_Filesystem; Root : String) return File_Vectors.Vector
   is
      Result : File_Vectors.Vector;
   begin
      for Item of Host.Writes.Data.Files loop
         declare
            Name : constant String := Unbounded.To_String (Item.Path);
         begin
            if Name'Length > Root'Length
              and then Name (Name'First .. Name'First + Root'Length)
                = Root & "/"
            then
               Result.Append (Item);
            end if;
         end;
      end loop;
      return Result;
   end Snapshot_Below;

   function Tree_Matches
     (Host : Fake_Filesystem; Root, Original_Root : String;
      Snapshot : File_Vectors.Vector) return Boolean;
   function Tree_Matches
     (Host : Fake_Filesystem; Root, Original_Root : String;
      Snapshot : File_Vectors.Vector) return Boolean
   is
      use type Ada.Containers.Count_Type;
      use type Unbounded.Unbounded_String;
   begin
      if Snapshot_Below (Host, Root).Length /= Snapshot.Length then
         return False;
      end if;
      for Item of Snapshot loop
         declare
            Name : constant String := Unbounded.To_String (Item.Path);
            At_Path : constant Natural := Find
              (Host, Root & Name
                 (Name'First + Original_Root'Length .. Name'Last));
         begin
            if At_Path = 0
              or else Host.Writes.Data.Files (At_Path).Identity
                /= Item.Identity
              or else Host.Writes.Data.Files (At_Path).Content /= Item.Content
              or else Item.Kind = A_Link
            then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Tree_Matches;

   overriding procedure Read_Snapshot
     (Host : Fake_Filesystem; Path : String;
      Content : out Unbounded.Unbounded_String;
      Identity : out Landin.Platform.File_Identity;
      Status : out Landin.Platform.Read_Status) is
   begin
      Read_File (Host, Path, Content, Status);
      Identity := (if Status = Landin.Platform.Read_Ok
                   then Identity_Of (Host, Path) else (others => <>));
   end Read_Snapshot;

   function Arena_Active (Host : Fake_Filesystem; Arena : Natural)
      return Boolean;
   function Arena_Active (Host : Fake_Filesystem; Arena : Natural)
      return Boolean is
   begin
      for Reservation of Host.Writes.Data.Publications loop
         if Reservation.Arena = Arena and then not Reservation.Finished then
            return True;
         end if;
      end loop;
      return False;
   end Arena_Active;

   overriding procedure Open_Publication
     (Host : Fake_Filesystem; Path : String; Delete_Only : Boolean;
      Root : String; Handle : out Landin.Platform.Publication_Handle;
      Stage : out Unbounded.Unbounded_String;
      Status : out Landin.Platform.Write_Status;
      Reason : out Unbounded.Unbounded_String;
      Require_Absent : Boolean := False)
   is
      use type Landin.Platform.Move_Status;
      pragma Unreferenced (Root);
      Existing : Natural;
      Slash : constant Natural := Ada.Strings.Fixed.Index
        (Path, "/", Ada.Strings.Backward);
      Parent : constant String :=
        (if Slash = 0 then "." else Path (Path'First .. Slash - 1));
      Name : constant String := Path (Slash + 1 .. Path'Last);
      Parent_Id : constant Landin.Platform.File_Identity :=
        Host.Identity_Of (Parent);
      Arena : Natural := Natural (Host.Writes.Data.Publications.Length) + 1;
      Item : Fake_Publication;
      Moved : Landin.Platform.Move_Status;
   begin
      Handle := Landin.Platform.No_Publication;
      Stage := Unbounded.Null_Unbounded_String;
      Reason := Unbounded.Null_Unbounded_String;
      Status := Landin.Platform.Not_Writable;
      if Host.Writes.Data.Cancelled then
         Reason := Unbounded.To_Unbounded_String
           ("cannot prepare " & Path & ": Interrupted system call;"
            & " choose an ordinary output root");
         return;
      end if;
      for Reservation of Host.Writes.Data.Publications loop
         if Arena_Active (Host, Reservation.Arena) then
            declare
               Prior_Parent : constant String :=
                 Unbounded.To_String (Reservation.Parent);
               Same_Parent : constant Boolean :=
                 (if Parent_Id.Valid and Reservation.Parent_Identity.Valid
                  then Parent_Id = Reservation.Parent_Identity
                    or else (Parent /= Prior_Parent
                             and then Host.Paths_Overlap
                               (Parent, Prior_Parent))
                  else Parent = Prior_Parent
                    or else Host.Paths_Overlap (Parent, Prior_Parent));
               Conflict : Boolean := Same_Parent
                 and then Unbounded.To_String (Reservation.Name) = Name;
            begin
               for Pair in 1 .. Natural (Host.Aliases.Length) / 2 loop
                  if (Host.Aliases (Pair * 2 - 1) = Path
                       and Host.Aliases (Pair * 2) =
                         Unbounded.To_String (Reservation.Path))
                    or else (Host.Aliases (Pair * 2) = Path
                       and Host.Aliases (Pair * 2 - 1) =
                         Unbounded.To_String (Reservation.Path))
                  then
                     Conflict := True;
                  end if;
               end loop;
               if Conflict then
                  Reason := Unbounded.To_Unbounded_String
                    ("output is reserved by or cannot be proved separate"
                     & " from active publication "
                     & Unbounded.To_String (Reservation.Path)
                     & "; retry after that transaction completes");
                  return;
               end if;
               if Same_Parent then
                  Arena := Reservation.Arena;
               end if;
            end;
         end if;
      end loop;
      if Host.Writes.Data.Appearance_Armed
        and then Host.Writes.Data.Appearance_Before_Open
        and then Unbounded.To_String
          (Host.Writes.Data.Appearance_Path) = Path
      then
         Host.Writes.Data.Appearance_Armed := False;
         Move_File
           (Host, Unbounded.To_String (Host.Writes.Data.Appearance_Target),
            Path, Moved);
         if Moved /= Landin.Platform.Moved then
            Reason := Unbounded.To_Unbounded_String
              ("the fake appearance could not move its entry");
            return;
         end if;
      end if;
      Existing := Find (Host, Path);
      if Require_Absent and then Existing /= 0 then
         Reason := Unbounded.To_Unbounded_String
           ("destination exists but absence was required;"
            & " choose another output");
         return;
      end if;
      if Host.Writes.Data.Refuses_Write or else Host.Is_Link (Path) then
         Reason := Unbounded.To_Unbounded_String
           ("output is linked or unwritable; choose another ordinary output");
         return;
      end if;
      for Index in Path'Range loop
         if Path (Index) = '/' and then Index > Path'First
           and then Host.Is_Link (Path (Path'First .. Index - 1))
         then
            Reason := Unbounded.To_Unbounded_String
              ("output parent is linked; choose an ordinary output root");
            return;
         end if;
      end loop;
      Item.Path := Unbounded.To_Unbounded_String (Path);
      Item.Parent := Unbounded.To_Unbounded_String (Parent);
      Item.Name := Unbounded.To_Unbounded_String (Name);
      Item.Parent_Identity := Parent_Id;
      Item.Arena := Arena;
      declare
         Private_Parent : constant String := Parent & "/.refine-publication/"
           & Ada.Strings.Fixed.Trim (Arena'Image, Ada.Strings.Both);
      begin
         Item.Stage := Unbounded.To_Unbounded_String
           (Private_Parent & "/" & Name);
         Item.Recovery := Unbounded.To_Unbounded_String
           (Private_Parent & "/.previous-" & Name);
      end;
      Item.Absent := Existing = 0;
      Item.Deletion := Delete_Only;
      if Existing /= 0 then
         Item.Expected := Host.Writes.Data.Files (Existing);
         Item.Expected_Tree := Snapshot_Below (Host, Path);
         if Item.Expected.Kind not in A_File | A_Directory then
            Reason := Unbounded.To_Unbounded_String
              ("output is not an ordinary file; choose another output");
            return;
         end if;
      end if;
      Host.Writes.Data.Publications.Append (Item);
      Handle := Landin.Platform.Publication_Handle
        (Host.Writes.Data.Publications.Length);
      Stage := Item.Stage;
      Status := Landin.Platform.Write_Ok;
   end Open_Publication;

   overriding procedure Advance_Publication
     (Host : Fake_Filesystem; Handle : Landin.Platform.Publication_Handle;
      Action : Landin.Platform.Publication_Action;
      Protected_Paths : Landin.Platform.Path_List;
      Protected_Identities : Landin.Platform.Identity_List;
      Status : out Landin.Platform.Write_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      use type Landin.Platform.Publication_Action;
      use type Landin.Platform.Move_Status;
      use type Landin.Platform.Remove_Status;
      use type Unbounded.Unbounded_String;
      Index : constant Positive := Positive (Handle);
      Item : Fake_Publication := Host.Writes.Data.Publications (Index);
      Path : constant String := Unbounded.To_String (Item.Path);
      Stage : constant String := Unbounded.To_String (Item.Stage);
      Recovery : constant String := Unbounded.To_String (Item.Recovery);
      At_Path : Natural;
      Moved : Landin.Platform.Move_Status;
      Removed : Landin.Platform.Remove_Status;

      procedure Record_Publication (Written_Item : File_Entry);
      procedure Record_Publication (Written_Item : File_Entry) is
      begin
         for Index in 1 .. Natural (Host.Writes.Data.Items.Length) loop
            if Host.Writes.Data.Items (Index).Path = Item.Path then
               Host.Writes.Data.Items.Replace_Element (Index, Written_Item);
               return;
            end if;
         end loop;
         Host.Writes.Data.Items.Append (Written_Item);
      end Record_Publication;

      procedure Save;
      procedure Save is
      begin
         Host.Writes.Data.Publications.Replace_Element (Index, Item);
      end Save;
      procedure Fail (Text : String);
      procedure Fail (Text : String) is
      begin
         Status := Landin.Platform.Not_Writable;
         --  As the native host does, the entries are named only while
         --  this publication holds them.
         Reason := Unbounded.To_Unbounded_String
           (Text & "; recovery directory "
            & Recovery (Recovery'First .. Ada.Strings.Fixed.Index
                          (Recovery, "/", Ada.Strings.Backward) - 1)
            & (if Item.Captured then "; previous entry " & Recovery else "")
            & (if Item.Rollback_Pending
               then "; captured new or concurrent entry " & Recovery & ".new"
               else ""));
         Save;
      end Fail;
   begin
      Status := Landin.Platform.Write_Ok;
      Reason := Unbounded.Null_Unbounded_String;
      if Item.Finished then
         return;
      end if;
      if Host.Writes.Data.Removal_Refusal_Armed
        and then Host.Writes.Data.Removal_Refusal_Action = Action
      then
         Host.Writes.Data.Removal_Refusal_Armed := False;
         Host.Writes.Data.Refuses_Removal := True;
      end if;
      if Host.Writes.Data.Cancel_Armed
        and then Host.Writes.Data.Cancel_Action = Action
      then
         Host.Writes.Data.Cancel_Armed := False;
         Host.Writes.Data.Cancelled := True;
      end if;
      if Host.Writes.Data.Cancelled
        and then Action in Landin.Platform.Validate_Stage
                         .. Landin.Platform.Install_Stage
      then
         Fail ("publication of " & Path & " failed: Interrupted system call");
         return;
      end if;
      if Host.Writes.Data.Appearance_Armed
        and then not Host.Writes.Data.Appearance_Before_Open
        and then Host.Writes.Data.Appearance_Action = Action
      then
         Host.Writes.Data.Appearance_Armed := False;
         Move_File
           (Host, Unbounded.To_String (Host.Writes.Data.Appearance_Target),
            Unbounded.To_String (Host.Writes.Data.Appearance_Path), Moved);
         if Moved /= Landin.Platform.Moved then
            Fail ("the fake appearance could not move its entry");
            return;
         end if;
      end if;
      if Host.Writes.Data.Mutation_Armed
        and then Host.Writes.Data.Mutation_Action = Action
      then
         declare
            Replacement : File_Entry := Host.Writes.Data.Mutation_File;
            Old : constant Natural := Find
              (Host, Unbounded.To_String (Replacement.Path));
         begin
            Host.Writes.Data.Mutation_Armed := False;
            Replacement.Identity := Host.Writes.Data.Next_Identity;
            Host.Writes.Data.Next_Identity :=
              Host.Writes.Data.Next_Identity + 1;
            if Old = 0 then
               Host.Writes.Data.Files.Append (Replacement);
            else
               Host.Writes.Data.Files.Replace_Element (Old, Replacement);
            end if;
         end;
      end if;
      case Action is
         when Landin.Platform.Validate_Stage =>
            if not Item.Deletion then
               At_Path := Find (Host, Stage);
               if At_Path = 0 or else Host.Is_Link (Stage) then
                  Fail ("staged output missing or linked");
                  return;
               end if;
               Item.Fresh := Host.Writes.Data.Files (At_Path);
               if Item.Fresh.Kind not in A_File | A_Directory then
                  Fail ("staged output is not an ordinary file or directory");
                  return;
               end if;
               declare
                  Tree : constant File_Vectors.Vector :=
                    Snapshot_Below (Host, Stage);
               begin
                  for Child of Tree loop
                     if Child.Kind not in A_File | A_Directory then
                        Fail ("staged tree has unexplained linked entries");
                        return;
                     end if;
                  end loop;
                  Item.Fresh_Tree := Tree;
               end;
               if not Item.Absent
                 and then Item.Fresh.Kind /= Item.Expected.Kind
               then
                  Fail ("output and staged artifact have different kinds");
                  return;
               end if;
            elsif not Item.Absent and then Item.Expected.Kind /= A_File then
               Fail ("a directory is not a stale generated file");
               return;
            end if;
         when Landin.Platform.Capture_Previous =>
            At_Path := Find (Host, Path);
            if At_Path = 0 then
               Move_File (Host, Path, Recovery, Moved);
               if Moved = Landin.Platform.Not_Movable then
                  Fail ("cannot establish expected absence");
                  return;
               end if;
               if not Item.Absent then
                  Fail ("expected output disappeared");
                  return;
               end if;
            else
               Move_File (Host, Path, Recovery, Moved);
               if Moved /= Landin.Platform.Moved then
                  Fail ("cannot capture previous output");
                  return;
               end if;
               Item.Captured := True;
               At_Path := Find (Host, Recovery);
               if Item.Absent
                 or else Host.Writes.Data.Files (At_Path).Identity
                   /= Item.Expected.Identity
                 or else Host.Writes.Data.Files (At_Path).Content
                   /= Item.Expected.Content
               then
                  Fail ("output changed after its snapshot");
                  return;
               end if;
               if not Tree_Matches
                 (Host, Recovery, Path, Item.Expected_Tree)
               then
                  Fail ("output directory contents changed after snapshot");
                  return;
               end if;
               for Identity of Protected_Identities loop
                  if Identity.Valid and then Identity.Device = 1
                    and then Identity.Inode = Item.Expected.Identity
                  then
                     Fail ("output aliases an original read input");
                     return;
                  end if;
               end loop;
               for Input of Protected_Paths loop
                  if Input = Path
                    or else Host.Paths_Overlap (Recovery, Input)
                  then
                     Fail ("output aliases a protected input");
                     return;
                  end if;
               end loop;
            end if;
         when Landin.Platform.Install_Stage =>
            if not Item.Deletion then
               if Item.Captured and then Item.Expected.Kind = A_File
                 and then Item.Expected.Content
                 = Item.Fresh.Content
               then
                  Move_File (Host, Recovery, Path, Moved);
                  if Moved /= Landin.Platform.Moved then
                     Fail ("cannot restore unchanged output");
                     return;
                  end if;
                  Item.Captured := False;
                  declare
                     Observed : File_Entry := Item.Expected;
                  begin
                     Observed.Path := Item.Path;
                     Record_Publication (Observed);
                  end;
               else
                  Move_File (Host, Stage, Path, Moved);
                  if Moved /= Landin.Platform.Moved then
                     Fail ("cannot install output without replacement");
                     return;
                  end if;
                  Item.Installed := True;
                  --  Existing observation API reports successful publication.
                  declare
                     Written_Item : File_Entry := Item.Fresh;
                  begin
                     Written_Item.Path := Item.Path;
                     Record_Publication (Written_Item);
                  end;
               end if;
            end if;
         when Landin.Platform.Restore_Previous =>
            if Item.Rollback_Pending then
               Fail ("previous captured concurrent entry retained");
               return;
            end if;
            if Item.Installed then
               At_Path := Find (Host, Path);
               if At_Path /= 0 then
                  declare
                     Rollback : constant String := Recovery & ".new";
                  begin
                     Move_File (Host, Path, Rollback, Moved);
                     if Moved /= Landin.Platform.Moved then
                        Fail ("cannot capture output during rollback");
                        return;
                     end if;
                     Item.Rollback_Pending := True;
                     At_Path := Find (Host, Rollback);
                     if Host.Writes.Data.Files (At_Path).Identity
                       /= Item.Fresh.Identity
                     then
                        Move_File (Host, Rollback, Path, Moved);
                        Item.Rollback_Pending :=
                          Moved /= Landin.Platform.Moved;
                        Fail ("concurrent save preserved during rollback");
                        return;
                     end if;
                     if Item.Fresh.Kind = A_Directory then
                        if not Tree_Matches
                          (Host, Rollback, Stage, Item.Fresh_Tree)
                        then
                           Fail ("new directory contents changed; retained");
                           return;
                        end if;
                        Remove_Tree (Host, Rollback, Removed);
                     else
                        Remove_File (Host, Rollback, Removed);
                     end if;
                     if Removed = Landin.Platform.Not_Removable then
                        Fail ("new output retained during rollback");
                        return;
                     end if;
                     Item.Rollback_Pending := False;
                  end;
               end if;
               Item.Installed := False;
            end if;
            if Item.Captured then
               Move_File (Host, Recovery, Path, Moved);
               if Moved /= Landin.Platform.Moved then
                  Fail ("previous output retained during rollback");
                  return;
               end if;
               Item.Captured := False;
            end if;
         when Landin.Platform.Finish_Publication =>
            if Item.Captured then
               if Item.Expected.Kind = A_Directory then
                  if not Tree_Matches
                    (Host, Recovery, Path, Item.Expected_Tree)
                  then
                     Fail ("old directory recovery contents changed");
                     return;
                  end if;
                  Remove_Tree (Host, Recovery, Removed);
               else
                  Remove_File (Host, Recovery, Removed);
               end if;
               if Removed = Landin.Platform.Not_Removable then
                  Fail ("cannot discard committed previous output");
                  return;
               end if;
               Item.Captured := False;
            end if;
            if Host.Is_Directory (Stage) then
               if not Tree_Matches (Host, Stage, Stage, Item.Fresh_Tree) then
                  Fail ("private staged directory has unexplained entries");
                  return;
               end if;
               Remove_Tree (Host, Stage, Removed);
            else
               Remove_File (Host, Stage, Removed);
            end if;
            if Removed = Landin.Platform.Not_Removable then
               Fail ("cannot clean private stage");
               return;
            end if;
            Item.Finished := True;
      end case;
      Save;
   end Advance_Publication;

   overriding procedure Read_For_Update
     (Host : Fake_Filesystem; Path : String;
      Content : out Unbounded.Unbounded_String;
      Lease : out Landin.Platform.Update_Handle;
      Status : out Landin.Platform.Read_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      Item : Fake_Update;
   begin
      Read_File (Host, Path, Content, Status);
      Reason := Unbounded.Null_Unbounded_String;
      Lease := Landin.Platform.No_Update;
      if Status /= Landin.Platform.Read_Ok then
         Reason := Unbounded.To_Unbounded_String
           ("cannot read original update object");
         return;
      end if;
      Item.Path := Unbounded.To_Unbounded_String (Path);
      Item.Original := Host.Writes.Data.Files (Resolve_Find (Host, Path));
      Host.Writes.Data.Updates.Append (Item);
      Lease := Landin.Platform.Update_Handle (Host.Writes.Data.Updates.Length);
   end Read_For_Update;

   overriding function Update_Identity
     (Host : Fake_Filesystem; Lease : Landin.Platform.Update_Handle)
      return Landin.Platform.File_Identity is
   begin
      return (Valid => True, Device => 1,
              Inode => Host.Writes.Data.Updates
                (Positive (Lease)).Original.Identity);
   end Update_Identity;

   overriding procedure Replace_Update
     (Host : Fake_Filesystem; Lease : Landin.Platform.Update_Handle;
      Content : String; Status : out Landin.Platform.Write_Status;
      Reason : out Unbounded.Unbounded_String)
   is
      use type Unbounded.Unbounded_String;
      Item : constant Fake_Update :=
        Host.Writes.Data.Updates (Positive (Lease));
      Index : constant Natural :=
        Resolve_Find (Host, Unbounded.To_String (Item.Path));
   begin
      Status := Landin.Platform.Not_Writable;
      Reason := Unbounded.To_Unbounded_String
        ("original read object changed; rerun or use fmt --stdout");
      if Item.Closed or else Index = 0
        or else Host.Writes.Data.Files (Index).Identity
          /= Item.Original.Identity
        or else Host.Writes.Data.Files (Index).Content /= Item.Original.Content
      then
         return;
      end if;
      Write_File (Host, Unbounded.To_String (Item.Path), Content, Status);
      if Status = Landin.Platform.Write_Ok then
         Reason := Unbounded.Null_Unbounded_String;
      else
         Reason := Unbounded.To_Unbounded_String
           ("the fake host refuses writes");
      end if;
   end Replace_Update;

   overriding procedure Close_Update
     (Host : Fake_Filesystem; Lease : Landin.Platform.Update_Handle)
   is
      Item : Fake_Update;
   begin
      if Lease /= Landin.Platform.No_Update then
         Item := Host.Writes.Data.Updates (Positive (Lease));
         Item.Closed := True;
         Host.Writes.Data.Updates.Replace_Element (Positive (Lease), Item);
      end if;
   end Close_Update;

   overriding procedure Remove_File
     (Host   : Fake_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Remove_Status)
   is
      Existing : constant Natural := Find (Host, Path);
   begin
      if Host.Writes.Data.Refuses_Removal then
         Status := Landin.Platform.Not_Removable;
      elsif Existing = 0 then
         Status := Landin.Platform.Already_Absent;
      elsif Host.Writes.Data.Files (Existing).Kind
        in A_Directory | An_Unlistable_Directory
      then
         Status := Landin.Platform.Not_Removable;
      else
         Host.Writes.Data.Files.Delete (Existing);
         Status := Landin.Platform.Removed;
      end if;
   end Remove_File;

   procedure Refuse_Private_Directories (Host : in out Fake_Filesystem) is
   begin
      Host.Writes.Data.Refuses_Private := True;
   end Refuse_Private_Directories;

   function Private_Directory_Count (Host : Fake_Filesystem) return Natural
     is (Host.Writes.Data.Private_Made);

   overriding procedure Make_Private_Directory
     (Host   : Fake_Filesystem;
      Prefix : String;
      Path   : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Landin.Platform.Write_Status)
   is
   begin
      if Host.Writes.Data.Refuses_Private then
         Path := Unbounded.Null_Unbounded_String;
         Status := Landin.Platform.Not_Writable;
         return;
      end if;
      Host.Writes.Data.Private_Made := Host.Writes.Data.Private_Made + 1;
      Path := Unbounded.To_Unbounded_String
        ("/virtual/tmp/" & Prefix
         & Ada.Strings.Fixed.Trim
             (Natural'Image (Host.Writes.Data.Private_Made),
              Ada.Strings.Both));
      Host.Writes.Data.Files.Append
        (File_Entry'
           (Path => Path, Content => Unbounded.Null_Unbounded_String,
            Kind => A_Directory,
            Identity => Host.Writes.Data.Next_Identity));
      Host.Writes.Data.Next_Identity := Host.Writes.Data.Next_Identity + 1;
      Status := Landin.Platform.Write_Ok;
   end Make_Private_Directory;

   overriding procedure Remove_Tree
     (Host   : Fake_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Remove_Status)
   is
      Under : constant String := Directory_Path (Path) & "/";
      Index : Positive := 1;
   begin
      if Host.Writes.Data.Refuses_Removal then
         Status := Landin.Platform.Not_Removable;
         return;
      elsif not Host.Is_Directory (Path) then
         Status := Landin.Platform.Already_Absent;
         return;
      end if;
      while Index <= Natural (Host.Writes.Data.Files.Length) loop
         declare
            Stored : constant String := Unbounded.To_String
              (Host.Writes.Data.Files.Element (Index).Path);
         begin
            if Stored = Directory_Path (Path)
              or else (Stored'Length >= Under'Length
                       and then Stored
                         (Stored'First .. Stored'First + Under'Length - 1)
                           = Under)
            then
               Host.Writes.Data.Files.Delete (Index);
            else
               Index := Index + 1;
            end if;
         end;
      end loop;
      Status := Landin.Platform.Removed;
   end Remove_Tree;

   overriding procedure Move_File
     (Host   : Fake_Filesystem;
      From, To : String;
      Status : out Landin.Platform.Move_Status)
   is
      Existing : constant Natural := Find (Host, From);
      Destination : constant Natural := Find (Host, To);
      Item : File_Entry;
   begin
      if Host.Writes.Data.Fails_Move then
         if Host.Writes.Data.Moves_Before_Failure = 0 then
            Host.Writes.Data.Fails_Move := False;
            Status := Landin.Platform.Not_Movable;
            return;
         end if;
         Host.Writes.Data.Moves_Before_Failure :=
           Host.Writes.Data.Moves_Before_Failure - 1;
      end if;
      if Existing = 0 then
         Status := Landin.Platform.Move_Source_Absent;
      elsif Host.Writes.Data.Refuses_Removal or else Destination /= 0 then
         Status := Landin.Platform.Not_Movable;
      else
         Item := Host.Writes.Data.Files (Existing);
         Item.Path := Unbounded.To_Unbounded_String (To);
         Host.Writes.Data.Files.Replace_Element (Existing, Item);
         if Item.Kind = A_Directory then
            for Index in 1 .. Natural (Host.Writes.Data.Files.Length) loop
               declare
                  Child : File_Entry := Host.Writes.Data.Files (Index);
                  Name : constant String := Unbounded.To_String (Child.Path);
               begin
                  if Name'Length > From'Length
                    and then Name (Name'First .. Name'First + From'Length)
                      = From & "/"
                  then
                     Child.Path := Unbounded.To_Unbounded_String
                       (To & Name (Name'First + From'Length .. Name'Last));
                     Host.Writes.Data.Files.Replace_Element (Index, Child);
                  end if;
               end;
            end loop;
         end if;
         Status := Landin.Platform.Moved;
      end if;
   end Move_File;

   overriding procedure Make_Directory
     (Host   : Fake_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Write_Status)
   is
      Existing : constant Natural := Find (Host, Path);
      Claimed : Boolean;
   begin
      if not Stage_Path_Usable (Host, Path, Claimed)
        or else (Claimed and then Existing /= 0)
      then
         Status := Landin.Platform.Not_Writable;
      elsif Existing /= 0 then
         Status :=
           (if Host.Writes.Data.Files (Existing).Kind = A_Directory
            then Landin.Platform.Write_Ok
            else Landin.Platform.Not_Writable);
      elsif Host.Writes.Data.Refuses_Write then
         Status := Landin.Platform.Not_Writable;
      else
         Host.Writes.Data.Files.Append
           (File_Entry'(Path => Unbounded.To_Unbounded_String
                          (Directory_Path (Path)),
                        Content => Unbounded.Null_Unbounded_String,
                        Kind => A_Directory,
                        Identity => Host.Writes.Data.Next_Identity));
         Host.Writes.Data.Next_Identity :=
           Host.Writes.Data.Next_Identity + 1;
         Status := Landin.Platform.Write_Ok;
      end if;
   end Make_Directory;

   overriding procedure Lock_Output
     (Host : Fake_Filesystem; Path : String; Handle : out Integer)
   is
      pragma Unreferenced (Path);
   begin
      if Host.Writes.Data.Output_Is_Locked then
         Handle := -1;
      else
         Host.Writes.Data.Output_Is_Locked := True;
         Handle := 0;
      end if;
   end Lock_Output;

   overriding procedure Unlock_Output
     (Host : Fake_Filesystem; Handle : Integer)
   is
      pragma Unreferenced (Handle);
   begin
      Host.Writes.Data.Output_Is_Locked := False;
   end Unlock_Output;

   ---------------------------------------------------------------------
   --  List_Directory
   --
   --  Immediate children only, sorted, matching the contract the native
   --  filesystem promises.  A fake that is more generous than the real host
   --  is a fake that hides bugs.
   ---------------------------------------------------------------------

   overriding procedure List_Directory
     (Host    : Fake_Filesystem;
      Path    : String;
      Entries : out Landin.Platform.Path_List;
      Status  : out Landin.Platform.List_Status)
   is
      package Sorting is new Landin.Platform.Path_Vectors.Generic_Sorting
        ("<" => "<");

      Index  : constant Natural := Find (Host, Path);
      Base   : constant String := Directory_Path (Path);
      Prefix : constant String :=
        (if Base'Length > 0 and then Base (Base'Last) = '/'
         then Base else Base & "/");
   begin
      Entries := Landin.Platform.Path_Vectors.Empty_Vector;

      for Call of Host.Writes.Data.List_Calls loop
         if Unbounded.To_String (Call.Path) = Path then
            Call.Count := Call.Count + 1;
            exit;
         end if;
      end loop;
      if List_Count (Host, Path) = 0 then
         Host.Writes.Data.List_Calls.Append
           (List_Call'
              (Path => Unbounded.To_Unbounded_String (Path), Count => 1));
      end if;

      if Index = 0 then
         Status := Landin.Platform.Directory_Not_Found;
         return;
      end if;

      if Host.Writes.Data.Files.Element (Index).Kind =
        An_Unlistable_Directory
      then
         Status := Landin.Platform.Directory_Not_Readable;
         return;
      end if;

      if Host.Writes.Data.Files.Element (Index).Kind /= A_Directory then
         Status := Landin.Platform.Not_A_Directory;
         return;
      end if;

      for Item of Host.Writes.Data.Files loop
         declare
            Full : constant String := Unbounded.To_String (Item.Path);
         begin
            if Full'Length > Prefix'Length
              and then Full (Full'First .. Full'First + Prefix'Length - 1)
                       = Prefix
            then
               declare
                  Tail : constant String :=
                    Full (Full'First + Prefix'Length .. Full'Last);
                  Slash : Boolean := False;
               begin
                  for Character_Index in Tail'Range loop
                     if Tail (Character_Index) = '/' then
                        Slash := True;
                     end if;
                  end loop;

                  if not Slash then
                     Entries.Append (Tail);
                  end if;
               end;
            end if;
         end;
      end loop;

      Sorting.Sort (Entries);
      Status := Landin.Platform.List_Ok;
   end List_Directory;

   ---------------------------------------------------------------------
   --  Tool runner
   ---------------------------------------------------------------------

   function Formatted_Command
     (Program : String; Arguments : Landin.Platform.Path_List) return String;

   function Formatted_Command
     (Program : String; Arguments : Landin.Platform.Path_List) return String
   is
      Line : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (Program);
   begin
      for Argument of Arguments loop
         Unbounded.Append (Line, " " & Argument);
      end loop;
      return Unbounded.To_String (Line);
   end Formatted_Command;

   procedure Set_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String;
      Ended     : Landin.Platform.Termination := Landin.Platform.Exited;
      Error_Output : String := "")
   is
   begin
      Host.State.Data.Mode := Repeating;
      Host.State.Data.Repeat :=
        (Ended     => Ended,
         Exit_Code => Exit_Code,
         Output    => Unbounded.To_Unbounded_String (Output),
         Error_Output => Unbounded.To_Unbounded_String (Error_Output));
      Host.State.Data.Script.Clear;
      Host.State.Data.Next_Result := 1;
   end Set_Result;

   procedure Add_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String;
      Ended     : Landin.Platform.Termination := Landin.Platform.Exited;
      Error_Output : String := "")
   is
   begin
      if Host.State.Data.Mode /= Ordered then
         Host.State.Data.Mode := Ordered;
         Host.State.Data.Script.Clear;
         Host.State.Data.Next_Result := 1;
      end if;

      Host.State.Data.Script.Append
        (Landin.Platform.Tool_Result'
           (Ended     => Ended,
            Exit_Code => Exit_Code,
            Output    => Unbounded.To_Unbounded_String (Output),
            Error_Output => Unbounded.To_Unbounded_String (Error_Output)));
   end Add_Result;

   function Call_At
     (Host : Fake_Tool_Runner; Index : Positive) return Tool_Call
   is
   begin
      if Index > Natural (Host.State.Data.Calls.Length) then
         raise Compiler_Defect with "fake tool call index is out of range";
      end if;

      return Host.State.Data.Calls.Element (Index);
   end Call_At;

   function Last_Command (Host : Fake_Tool_Runner) return String is
   begin
      if Host.State.Data.Calls.Is_Empty then
         return "";
      end if;

      declare
         Call : constant Tool_Call := Host.State.Data.Calls.Last_Element;
      begin
         return Formatted_Command
           (Unbounded.To_String (Call.Program), Call.Arguments);
      end;
   end Last_Command;

   function Run_Count (Host : Fake_Tool_Runner) return Natural
     is (Natural (Host.State.Data.Calls.Length));

   procedure Set_Available
     (Host : in out Fake_Tool_Runner; Found : Boolean) is
   begin
      Host.Tool_Available := Found;
   end Set_Available;

   procedure Set_Absent
     (Host : in out Fake_Tool_Runner; Program : String) is
   begin
      Host.Absent.Append (Program);
   end Set_Absent;

   overriding function Available
     (Host : Fake_Tool_Runner; Program : String) return Boolean
   is (Host.Tool_Available and then not Host.Absent.Contains (Program));

   function Last_Capture
     (Host : Fake_Tool_Runner) return Landin.Platform.Capture_Mode
   is
   begin
      if Host.State.Data.Calls.Is_Empty then
         return Landin.Platform.Merged;
      end if;

      return Host.State.Data.Calls.Last_Element.Capture;
   end Last_Capture;

   procedure Raise_On_Run
     (Host : in out Fake_Tool_Runner;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity;
      Message : String :=
        "a fake tool was asked to stand in for a compiler defect")
   is
   begin
      Host.State.Data.Raises := True;
      Host.State.Data.Run_Exception := Reason;
      Host.State.Data.Run_Message := Unbounded.To_Unbounded_String (Message);
   end Raise_On_Run;

   procedure Set_Program_Result
     (Host        : in out Fake_Tool_Runner;
      Exit_Code   : Integer;
      Signal      : Natural := 0;
      Signal_Name : String := "") is
   begin
      Host.State.Data.Program :=
        (Ended => (if Signal = 0 then Landin.Platform.Exited
                   else Landin.Platform.Signaled),
         Exit_Code => (if Signal = 0 then Exit_Code else 0),
         Signal => Signal,
         Signal_Name => Unbounded.To_Unbounded_String (Signal_Name));
   end Set_Program_Result;

   overriding procedure Run_Attached
     (Host      : Fake_Tool_Runner;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Result    : out Landin.Platform.Program_Result)
   is
   begin
      Host.State.Data.Calls.Append
        (Tool_Call'
           (Program   => Unbounded.To_Unbounded_String (Program),
            Arguments => Arguments,
            Capture   => Landin.Platform.Merged,
            Attached  => True,
            others    => <>));
      if Host.State.Data.Raises then
         Host.State.Data.Raises := False;
         Ada.Exceptions.Raise_Exception
           (Host.State.Data.Run_Exception,
            Unbounded.To_String (Host.State.Data.Run_Message));
      end if;
      Result := Host.State.Data.Program;
   end Run_Attached;

   overriding procedure Run_In_Environment
     (Host        : Fake_Tool_Runner;
      Program     : String;
      Arguments   : Landin.Platform.Path_List;
      Environment : Landin.Platform.Path_List;
      Result      : out Landin.Platform.Tool_Result;
      Capture     : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
   is
   begin
      Fake_Tool_Runner'Class (Host).Run (Program, Arguments, Result, Capture);
      declare
         Last : Tool_Call := Host.State.Data.Calls.Last_Element;
      begin
         Last.Environment := Environment;
         Last.Isolated := True;
         Host.State.Data.Calls.Replace_Element
           (Host.State.Data.Calls.Last_Index, Last);
      end;
   end Run_In_Environment;

   overriding function Resolve_Program
     (Host : Fake_Tool_Runner; Program : String) return String is
   begin
      return (if Available (Host, Program) then Program else "");
   end Resolve_Program;

   overriding procedure Run
     (Host      : Fake_Tool_Runner;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Result    : out Landin.Platform.Tool_Result;
      Capture   : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
   is
   begin
      if Host.State.Data.Raises then
         Host.State.Data.Raises := False;
         Ada.Exceptions.Raise_Exception
           (Host.State.Data.Run_Exception,
            Unbounded.To_String (Host.State.Data.Run_Message));
      end if;

      if Host.State.Data.Mode = Ordered then
         if Host.State.Data.Next_Result >
           Natural (Host.State.Data.Script.Length)
         then
            raise Compiler_Defect
              with "fake tool script exhausted before: "
                   & Formatted_Command (Program, Arguments);
         end if;

         Result :=
           Host.State.Data.Script.Element (Host.State.Data.Next_Result);
         Host.State.Data.Next_Result := Host.State.Data.Next_Result + 1;
      else
         Result := Host.State.Data.Repeat;
      end if;

      Host.State.Data.Calls.Append
        (Tool_Call'
           (Program   => Unbounded.To_Unbounded_String (Program),
            Arguments => Arguments,
            Capture   => Capture,
            Attached  => False,
            others    => <>));
      if Host.State.Data.Output_Store /= null then
         if Host.State.Data.Moves_Backup_Back
           and then Result.Ended = Landin.Platform.Exited
           and then Result.Exit_Code = 0
         then
            declare
               Store_Value : constant Store_Access :=
                 Host.State.Data.Output_Store;
               Path : constant String :=
                 Unbounded.To_String (Host.State.Data.Output_Path);
            begin
               for Reservation of Store_Value.Publications loop
                  if Unbounded.To_String (Reservation.Stage) = Path
                    and then not Reservation.Absent
                  then
                     declare
                        Item : File_Entry := Reservation.Expected;
                     begin
                        Item.Path := Unbounded.To_Unbounded_String (Path);
                        Store_Value.Files.Append (Item);
                     end;
                     exit;
                  end if;
               end loop;
               for Index in 1 .. Natural (Store_Value.Files.Length) loop
                  if Unbounded.To_String
                    (Store_Value.Files.Element (Index).Path) =
                    Path & ".landin-backup-1"
                  then
                     declare
                        Item : File_Entry :=
                          Store_Value.Files.Element (Index);
                     begin
                        Item.Path := Unbounded.To_Unbounded_String (Path);
                        Store_Value.Files.Replace_Element (Index, Item);
                     end;
                     exit;
                  end if;
               end loop;
            end;
         elsif Host.State.Data.Produces_Output
           and then Result.Ended = Landin.Platform.Exited
           and then Result.Exit_Code = 0
         then
            declare
               Store_Value : constant Store_Access :=
                 Host.State.Data.Output_Store;
               Path : constant String :=
                 Unbounded.To_String (Host.State.Data.Output_Path);
               Item : File_Entry :=
                 (Unbounded.To_Unbounded_String (Path),
                  Host.State.Data.Output_Content,
                  (if Program = "/usr/bin/dsymutil" then A_Directory
                   else A_File), 0);
               Found : Natural := 0;
            begin
               Item.Identity := Store_Value.Next_Identity;
               Store_Value.Next_Identity := Store_Value.Next_Identity + 1;
               for Index in 1 .. Natural (Store_Value.Files.Length) loop
                  if Unbounded.To_String
                    (Store_Value.Files.Element (Index).Path) = Path
                  then
                     Found := Index;
                     exit;
                  end if;
               end loop;
               if Store_Value.Refuses_Write
                 or else (Found /= 0
                   and then Store_Value.Files.Element (Found).Kind =
                     A_Directory)
               then
                  null;
               elsif Found = 0 then
                  Store_Value.Files.Append (Item);
               else
                  Store_Value.Files.Replace_Element (Found, Item);
               end if;
               if not Store_Value.Refuses_Write
                 and then (Found = 0
                   or else Store_Value.Files.Element (Found).Kind /=
                     A_Directory)
               then
                  Found := 0;
                  for Index in 1 .. Natural (Store_Value.Items.Length) loop
                     if Unbounded.To_String
                       (Store_Value.Items.Element (Index).Path) = Path
                     then
                        Found := Index;
                        exit;
                     end if;
                  end loop;
                  if Found = 0 then
                     Store_Value.Items.Append (Item);
                  else
                     Store_Value.Items.Replace_Element (Found, Item);
                  end if;
               end if;
            end;
         end if;
      end if;
      if Host.State.Data.Output_Store /= null
        and then Host.State.Data.Produces_Output
        and then Result.Ended = Landin.Platform.Exited
        and then Result.Exit_Code = 0
        and then (Arguments.Contains ("-save-temps=obj")
                  or else Arguments.Contains ("-Map"))
      then
         declare
            Data : constant Store_Access := Host.State.Data.Output_Store;
            Main_Path : constant String :=
              Unbounded.To_String (Host.State.Data.Output_Path);
         begin
            for Reservation of Data.Publications loop
               declare
                  Name : constant String :=
                    Unbounded.To_String (Reservation.Stage);
               begin
                  if (Arguments.Contains ("-save-temps=obj")
                      and then (Name = Main_Path & ".o"
                                or else Name = Main_Path & ".dSYM"))
                    or else (Arguments.Contains ("-Map")
                             and then Name = Main_Path & ".map")
                  then
                     Data.Files.Append
                       (File_Entry'
                          (Path => Reservation.Stage,
                           Content => Host.State.Data.Output_Content,
                           Kind => (if Name = Main_Path & ".dSYM"
                                    then A_Directory else A_File),
                           Identity => Data.Next_Identity));
                     Data.Next_Identity := Data.Next_Identity + 1;
                  end if;
               end;
            end loop;
         end;
      end if;
      Host.State.Data.Output_Store := null;
   end Run;

   procedure Set_Output_Produced
     (Host : in out Fake_Tool_Runner; Produced : Boolean)
   is
   begin
      Host.State.Data.Produces_Output := Produced;
   end Set_Output_Produced;

   procedure Set_Output_Content
     (Host : in out Fake_Tool_Runner; Content : String)
   is
   begin
      Host.State.Data.Output_Content := Unbounded.To_Unbounded_String
        (Content);
   end Set_Output_Content;

   procedure Set_Move_Backup_Back (Host : in out Fake_Tool_Runner) is
   begin
      Host.State.Data.Moves_Backup_Back := True;
   end Set_Move_Backup_Back;

   overriding function Output_Produced
     (Host : Fake_Tool_Runner; Files : Landin.Platform.Filesystem'Class;
      Path : String) return Boolean
   is
      pragma Unreferenced (Host);
   begin
      return Files.Exists (Path) and then not Files.Is_Directory (Path);
   end Output_Produced;

   overriding procedure Prepare_Output
     (Host : Fake_Tool_Runner; Files : Landin.Platform.Filesystem'Class;
      Path : String)
   is
   begin
      Host.State.Data.Output_Store := Fake_Filesystem (Files).Writes.Data;
      Host.State.Data.Output_Path := Unbounded.To_Unbounded_String (Path);
   end Prepare_Output;

   ---------------------------------------------------------------------
   --  Channel
   ---------------------------------------------------------------------

   procedure Script
     (Host : in out Fake_Channel; Input : String; Chunk : Positive := 4096)
   is
   begin
      Host.Input := Unbounded.To_Unbounded_String (Input);
      Host.Next := 1;
      Host.Chunk := Chunk;
   end Script;

   procedure Script_Unbounded
     (Host  : in out Fake_Channel;
      Input : Ada.Strings.Unbounded.Unbounded_String;
      Chunk : Positive := 4096)
   is
   begin
      Host.Input := Input;
      Host.Next := 1;
      Host.Chunk := Chunk;
   end Script_Unbounded;

   function Output (Host : Fake_Channel) return String
     is (Unbounded.To_String (Host.Output));

   function Logged (Host : Fake_Channel) return String
     is (Unbounded.To_String (Host.Log));

   procedure Pause_At (Host : in out Fake_Channel; Offset : Natural) is
   begin
      Host.Pauses.Append (Offset);
   end Pause_At;

   procedure Edit_At
     (Host : in out Fake_Channel; Offset : Natural;
      Files : Fake_Filesystem_Access; Path, Content : String)
   is
   begin
      Host.Files := Files;
      Host.Edits.Append
        (Timed_Edit'
           (Offset  => Offset,
            Path    => Unbounded.To_Unbounded_String (Path),
            Content => Unbounded.To_Unbounded_String (Content),
            Removes => False));
   end Edit_At;

   procedure Remove_At
     (Host : in out Fake_Channel; Offset : Natural;
      Files : Fake_Filesystem_Access; Path : String)
   is
   begin
      Host.Files := Files;
      Host.Edits.Append
        (Timed_Edit'
           (Offset  => Offset,
            Path    => Unbounded.To_Unbounded_String (Path),
            Content => Unbounded.Null_Unbounded_String,
            Removes => True));
   end Remove_At;

   --  The input left before the next pause, in bytes.
   function Before_Pause (Host : Fake_Channel) return Natural;

   function Before_Pause (Host : Fake_Channel) return Natural is
      Consumed : constant Natural := Host.Next - 1;
   begin
      for Offset of Host.Pauses loop
         if Offset > Consumed then
            return Offset - Consumed;
         end if;
      end loop;
      return Unbounded.Length (Host.Input) - Consumed;
   end Before_Pause;

   --  A read stops at the next pause; Before_Pause has already moved on to
   --  the one after it when a read starts at one.
   overriding procedure Read
     (Host : in out Fake_Channel;
      Into : out String;
      Last : out Natural)
   is
   begin
      while Host.Next_Edit <= Natural (Host.Edits.Length)
        and then Host.Edits (Host.Next_Edit).Offset = Host.Next - 1
      loop
         declare
            Edit : constant Timed_Edit := Host.Edits (Host.Next_Edit);
            Path : constant String := Unbounded.To_String (Edit.Path);
            Gone : Landin.Platform.Remove_Status;
         begin
            if not Edit.Removes then
               Add_File
                 (Host.Files.all, Path, Unbounded.To_String (Edit.Content));
            elsif Host.Files.Is_Directory (Path) then
               Host.Files.Remove_Tree (Path, Gone);
            else
               Host.Files.Remove_File (Path, Gone);
            end if;
            Host.Next_Edit := Host.Next_Edit + 1;
         end;
      end loop;
      declare
         Left : constant Natural :=
           (if Before_Pause (Host) = 0
            then Unbounded.Length (Host.Input) - Host.Next + 1
            else Before_Pause (Host));
         Taken : constant Natural :=
           Natural'Min (Left, Natural'Min (Into'Length, Host.Chunk));
      begin
         Last := Into'First + Taken - 1;
         if Taken > 0 then
            Into (Into'First .. Last) := Unbounded.Slice
              (Host.Input, Host.Next, Host.Next + Taken - 1);
            Host.Next := Host.Next + Taken;
         end if;
      end;
   end Read;

   --  At a pause, the editor is waiting: nothing is ready, though more
   --  will come once the server reads again.
   overriding function Pending (Host : in out Fake_Channel) return Boolean
     is (Host.Next <= Unbounded.Length (Host.Input)
         and then not (for some Offset of Host.Pauses =>
                         Offset = Host.Next - 1));

   overriding procedure Write (Host : in out Fake_Channel; Item : String) is
   begin
      Unbounded.Append (Host.Output, Item);
   end Write;

   overriding procedure Log (Host : in out Fake_Channel; Line : String) is
   begin
      Unbounded.Append (Host.Log, Line & ASCII.LF);
   end Log;

end Landin.Testing.Fakes;
