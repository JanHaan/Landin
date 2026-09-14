with Ada.Unchecked_Deallocation;

package body Landin.Testing.Fakes is

   use type Landin.Platform.Read_Status;

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
              or else (Item.Kind = A_Directory
                       and then Stored = Directory_Path (Path))
            then
               return Index;
            end if;
         end;
      end loop;
      return 0;
   end Find;

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
      Item     : constant File_Entry :=
        (Path    => Unbounded.To_Unbounded_String (Path),
         Content => Unbounded.To_Unbounded_String (Text),
         Kind    => Kind);
   begin
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

   procedure Add_Directory (Host : in out Fake_Filesystem; Path : String) is
   begin
      Add (Host, Directory_Path (Path), "", A_Directory);
   end Add_Directory;

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

   overriding function Exists
     (Host : Fake_Filesystem; Path : String) return Boolean
     is (Find (Host, Path) /= 0);

   procedure Add_Alias
     (Host : in out Fake_Filesystem; Left, Right : String) is
   begin
      Host.Aliases.Append (Left);
      Host.Aliases.Append (Right);
   end Add_Alias;

   overriding function Same_File
     (Host : Fake_Filesystem; Left, Right : String) return Boolean
     is (Host.Exists (Left) and then Host.Exists (Right)
         and then Host.Paths_Overlap (Left, Right));

   overriding function Paths_Overlap
     (Host : Fake_Filesystem; Left, Right : String) return Boolean is
   begin
      if Left = Right
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

   overriding function Is_Directory
     (Host : Fake_Filesystem; Path : String) return Boolean
   is
      Index : constant Natural := Find (Host, Path);
   begin
      return Index /= 0
        and then Host.Writes.Data.Files.Element (Index).Kind = A_Directory;
   end Is_Directory;

   procedure Raise_On_Read
     (Host : in out Fake_Filesystem;
      Reason : Ada.Exceptions.Exception_Id := Compiler_Defect'Identity) is
   begin
      Host.Writes.Data.Raises := True;
      Host.Writes.Data.Read_Exception := Reason;
   end Raise_On_Read;

   overriding procedure Read_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Landin.Platform.Read_Status)
   is
      Index : constant Natural := Find (Host, Path);
   begin
      Content := Unbounded.Null_Unbounded_String;

      if Host.Writes.Data.Raises then
         Host.Writes.Data.Raises := False;
         Ada.Exceptions.Raise_Exception
           (Host.Writes.Data.Read_Exception,
            "a fake read injected an exception");
      end if;

      if Index = 0 then
         Status := Landin.Platform.Not_Found;
         return;
      end if;

      case Host.Writes.Data.Files.Element (Index).Kind is
         when A_File =>
            Content := Host.Writes.Data.Files.Element (Index).Content;
            Status := Landin.Platform.Read_Ok;
         when A_Directory | An_Unreadable_File =>
            Status := Landin.Platform.Not_Readable;
      end case;
   end Read_File;

   procedure Refuse_Writes (Host : in out Fake_Filesystem) is
   begin
      Host.Writes.Data.Refuses_Write := True;
   end Refuse_Writes;

   overriding procedure Write_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status)
   is
      Existing : constant Natural := Find (Host, Path);
      Entry_Value : constant File_Entry :=
        (Path    => Unbounded.To_Unbounded_String (Path),
         Content => Unbounded.To_Unbounded_String (Content),
         Kind    => A_File);
   begin
      Host.Writes.Data.Write_Attempts := Host.Writes.Data.Write_Attempts + 1;
      if Host.Writes.Data.Refuses_Write
        or else (Existing /= 0
                 and then Host.Writes.Data.Files (Existing).Kind = A_Directory)
      then
         Status := Landin.Platform.Not_Writable;
         return;
      end if;

      if Existing = 0 then
         Host.Writes.Data.Files.Append (Entry_Value);
      else
         Host.Writes.Data.Files.Replace_Element (Existing, Entry_Value);
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

   procedure Refuse_Removals (Host : in out Fake_Filesystem) is
   begin
      Host.Writes.Data.Refuses_Removal := True;
   end Refuse_Removals;

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
      elsif Host.Writes.Data.Files (Existing).Kind = A_Directory then
         Status := Landin.Platform.Not_Removable;
      else
         Host.Writes.Data.Files.Delete (Existing);
         Status := Landin.Platform.Removed;
      end if;
   end Remove_File;

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

      if Index = 0 then
         Status := Landin.Platform.Directory_Not_Found;
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
            Capture   => Capture));
   end Run;

end Landin.Testing.Fakes;
