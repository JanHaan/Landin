package body Landin.Testing.Fakes is

   use type Landin.Platform.Read_Status;

   function Find
     (Host : Fake_Filesystem; Path : String) return Natural;

   function Find
     (Host : Fake_Filesystem; Path : String) return Natural
   is
   begin
      for Index in 1 .. Natural (Host.Items.Length) loop
         if Unbounded.To_String (Host.Items.Element (Index).Path) = Path then
            return Index;
         end if;
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
         Host.Items.Append (Item);
      else
         Host.Items.Replace_Element (Existing, Item);
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
      Add (Host, Path, "", A_Directory);
   end Add_Directory;

   procedure Add_Unreadable (Host : in out Fake_Filesystem; Path : String) is
   begin
      Add (Host, Path, "", An_Unreadable_File);
   end Add_Unreadable;

   function Written (Host : Fake_Filesystem; Path : String) return String is
   begin
      for Item of Host.Writes.Items loop
         if Unbounded.To_String (Item.Path) = Path then
            return Unbounded.To_String (Item.Content);
         end if;
      end loop;
      return "";
   end Written;

   overriding function Exists
     (Host : Fake_Filesystem; Path : String) return Boolean
     is (Find (Host, Path) /= 0);

   overriding function Is_Directory
     (Host : Fake_Filesystem; Path : String) return Boolean
   is
      Index : constant Natural := Find (Host, Path);
   begin
      return Index /= 0
        and then Host.Items.Element (Index).Kind = A_Directory;
   end Is_Directory;

   overriding procedure Read_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Landin.Platform.Read_Status)
   is
      Index : constant Natural := Find (Host, Path);
   begin
      Content := Unbounded.Null_Unbounded_String;

      if Index = 0 then
         Status := Landin.Platform.Not_Found;
         return;
      end if;

      case Host.Items.Element (Index).Kind is
         when A_File =>
            Content := Host.Items.Element (Index).Content;
            Status := Landin.Platform.Read_Ok;
         when A_Directory | An_Unreadable_File =>
            Status := Landin.Platform.Not_Readable;
      end case;
   end Read_File;

   overriding procedure Write_File
     (Host    : Fake_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status)
   is
   begin
      Host.Writes.Items.Append
        (File_Entry'
           (Path    => Unbounded.To_Unbounded_String (Path),
            Content => Unbounded.To_Unbounded_String (Content),
            Kind    => A_File));
      Status := Landin.Platform.Write_Ok;
   end Write_File;

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
      Prefix : constant String := Path & "/";
   begin
      Entries := Landin.Platform.Path_Vectors.Empty_Vector;

      if Index = 0 then
         Status := Landin.Platform.Directory_Not_Found;
         return;
      end if;

      if Host.Items.Element (Index).Kind /= A_Directory then
         Status := Landin.Platform.Not_A_Directory;
         return;
      end if;

      for Item of Host.Items loop
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

   procedure Set_Result
     (Host      : in out Fake_Tool_Runner;
      Exit_Code : Integer;
      Output    : String)
   is
   begin
      Host.State.Exit_Code := Exit_Code;
      Host.State.Output := Unbounded.To_Unbounded_String (Output);
   end Set_Result;

   function Last_Command (Host : Fake_Tool_Runner) return String
     is (Unbounded.To_String (Host.State.Command));

   function Run_Count (Host : Fake_Tool_Runner) return Natural
     is (Host.State.Runs);

   function Last_Capture
     (Host : Fake_Tool_Runner) return Landin.Platform.Capture_Mode
     is (Host.State.Capture);

   overriding procedure Run
     (Host      : Fake_Tool_Runner;
      Program   : String;
      Arguments : Landin.Platform.Path_List;
      Result    : out Landin.Platform.Tool_Result;
      Capture   : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
   is
      Line : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (Program);
   begin
      for Argument of Arguments loop
         Unbounded.Append (Line, " " & Argument);
      end loop;

      Host.State.Command := Line;
      Host.State.Runs := Host.State.Runs + 1;
      Host.State.Capture := Capture;

      Result :=
        (Exit_Code => Host.State.Exit_Code,
         Output    => Host.State.Output);
   end Run;

end Landin.Testing.Fakes;
