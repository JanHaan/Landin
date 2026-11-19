with Ada.Strings.Fixed;
with Landin.Commands.Catalogue;
with Landin.Json;
with Landin.Paths;

package body Landin.Commands.External is

   package US renames Ada.Strings.Unbounded;
   package J renames Landin.Json;
   use type US.Unbounded_String;
   LF : constant Character := ASCII.LF;

   Prefix : constant String := "refine-";

   function Is_Command_Name (Word : String) return Boolean is
     (Word'Length > 0
      and then Word (Word'First) in 'a' .. 'z' | 'A' .. 'Z'
      and then (for all Letter of Word =>
                  Letter in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
                    | '-' | '_'));

   function Names (List : String) return Landin.Platform.Path_List is
      Result : Landin.Platform.Path_List;
      First : Positive := List'First;
   begin
      for Index in List'Range loop
         if List (Index) = ' ' then
            if Index > First then
               Result.Append (List (First .. Index - 1));
            end if;
            First := Index + 1;
         end if;
      end loop;
      if First <= List'Last then
         Result.Append (List (First .. List'Last));
      end if;
      return Result;
   end Names;

   --  The directory Path is in, or "" at the top.
   function Parent (Path : String) return String;

   function Parent (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      if Slash <= Path'First then
         return "";
      end if;
      return Path (Path'First .. Slash - 1);
   end Parent;

   function Shipped_Path
     (Host : Landin.Platform.Filesystem'Class; Name : String) return String
   is
      Binaries : constant String := Host.Executable_Directory;
      Prefix_Directory : constant String :=
        (if Binaries = "" then "" else Parent (Binaries));
   begin
      if Prefix_Directory = "" then
         return "";
      end if;
      return Landin.Paths.Joined_Path
        (Prefix_Directory, "libexec/landin/" & Prefix & Name);
   end Shipped_Path;

   function Locate
     (Name    : String;
      Host    : Landin.Platform.Filesystem'Class;
      Tools   : Landin.Platform.Tool_Runner'Class;
      Shipped : Landin.Platform.Path_List) return Location
   is
   begin
      if Shipped.Contains (Name) then
         declare
            Path : constant String := Shipped_Path (Host, Name);
         begin
            return
              (Of_Kind => (if Path /= "" and then Host.Exists (Path)
                             and then not Host.Is_Directory (Path)
                           then External.Shipped else Shipped_Missing),
               Path => US.To_Unbounded_String (Path));
         end;
      end if;
      for Path of Tools.Programs_On_Path (Prefix & Name) loop
         if Path'Length >= Prefix'Length + Name'Length
           and then Path (Path'Last - Prefix'Length - Name'Length + 1
                          .. Path'Last) = Prefix & Name
         then
            return (Of_Kind => Contributed,
                    Path => US.To_Unbounded_String (Path));
         end if;
      end loop;
      return (Of_Kind => Absent, Path => US.Null_Unbounded_String);
   end Locate;

   function Short (Text : String) return String is
     (Text (Text'First .. Text'First + Natural'Min (12, Text'Length) - 1));

   function Is_Prefix (Text : String) return Boolean is
     (Text'Length in 2 .. 8
      and then (for all Letter of Text => Letter in 'A' .. 'Z'));

   function Describe
     (Name, Path : String;
      Is_Shipped : Boolean;
      Tools      : Landin.Platform.Tool_Runner'Class;
      Digest     : String) return Description
   is
      use type Landin.Platform.Termination;
      Result : Description;
      Ran : Landin.Platform.Tool_Result;
      Document : J.Document;
      procedure Refuse (Reason : String);
      procedure Refuse (Reason : String) is
      begin
         Result.Compatible := False;
         Result.Reason := US.To_Unbounded_String (Reason);
      end Refuse;
   begin
      begin
         Tools.Run_Within
           (Path, Landin.Platform.Arguments ("--describe"),
            Description_Limit, Ran, Landin.Platform.Output_Only);
      exception
         when Failure : Landin.External_Tool_Failed =>
            Refuse ("it could not be started: "
              & Landin.Platform.Tool_Failure_Reason (Tools, Failure));
            return Result;
      end;
      if Ran.Ended = Landin.Platform.Timed_Out then
         Refuse ("it did not answer within"
           & Natural'Image (Natural (Description_Limit)) & " seconds");
         return Result;
      elsif Ran.Ended = Landin.Platform.Signaled then
         Refuse ("a signal ended it");
         return Result;
      elsif Ran.Exit_Code /= 0 then
         Refuse ("it exited with status" & Integer'Image (Ran.Exit_Code));
         return Result;
      end if;
      J.Parse (Document, US.To_String (Ran.Output));
      if not J.Ok (Document) then
         Refuse ("its answer is not JSON: " & J.Fault (Document)
           & " at byte" & Natural'Image (J.Fault_At (Document)));
         return Result;
      end if;
      declare
         Root : constant J.Value := J.Root (Document);
         Format : constant J.Value := J.Member (Document, Root, "format");
         Named : constant J.Value := J.Member (Document, Root, "name");
         Summary : constant J.Value := J.Member (Document, Root, "summary");
         Codes : constant J.Value := J.Member (Document, Root, "codes");
         Source : constant J.Value :=
           J.Member (Document, Root, "source_digest");
      begin
         if not J.Is_Kind (Document, Root, J.Object_Value) then
            Refuse ("its answer is not a JSON object");
         elsif not J.Is_Kind (Document, Format, J.String_Value) then
            Refuse ("its answer has no ""format"" string, and this refine"
              & " reads "
              & Description_Format);
         elsif J.Text (Document, Format) /= Description_Format then
            Refuse ("it answered in format "
              & J.Text (Document, Format) & ", and this refine reads "
              & Description_Format);
         elsif not J.Is_Kind (Document, Named, J.String_Value) then
            Refuse ("its answer has no ""name"" string");
         elsif J.Text (Document, Named) /= Name then
            Refuse ("it names itself " & J.Text (Document, Named)
              & ", not " & Name);
         elsif not J.Is_Kind (Document, Summary, J.String_Value) then
            Refuse ("its answer has no ""summary"" string");
         elsif not J.Is_Kind (Document, Codes, J.Array_Value) then
            Refuse ("its answer has no ""codes"" array");
         else
            Result.Compatible := True;
            Result.Summary := US.To_Unbounded_String
              (J.Text (Document, Summary));
            for Position in 1 .. J.Length (Document, Codes) loop
               declare
                  Item : constant J.Value :=
                    J.Element (Document, Codes, Position);
               begin
                  if J.Is_Kind (Document, Item, J.String_Value)
                    and then J.Text (Document, Item) = "L"
                  then
                     Refuse ("it claims L, the prefix of Landin's own codes");
                     return Result;
                  elsif not J.Is_Kind (Document, Item, J.String_Value)
                    or else not Is_Prefix (J.Text (Document, Item))
                  then
                     Refuse ("it claims a code prefix that is not two to"
                       & " eight capital letters");
                     return Result;
                  end if;
                  Result.Codes.Append (J.Text (Document, Item));
               end;
            end loop;
            if Is_Shipped then
               if not Result.Codes.Is_Empty then
                  Refuse ("it claims the code prefix " & Result.Codes (1)
                    & ", but a shipped command uses only L codes from"
                    & " Landin's catalogue");
               elsif not J.Is_Kind (Document, Source, J.String_Value) then
                  Refuse ("its answer has no ""source_digest"" string");
               elsif J.Text (Document, Source) /= Digest then
                  Refuse ("it was built from compiler sources "
                    & Short (J.Text (Document, Source))
                    & ", and this refine from " & Short (Digest));
               end if;
            end if;
         end if;
      end;
      return Result;
   end Describe;

   function Scan
     (Host        : Landin.Platform.Filesystem'Class;
      Tools       : Landin.Platform.Tool_Runner'Class;
      Shipped     : Landin.Platform.Path_List;
      Digest      : String;
      Contributed : Boolean := False) return Found_Vectors.Vector
   is
      Result : Found_Vectors.Vector;
   begin
      if not Contributed then
         for Name of Shipped loop
            declare
               Where : constant Location :=
                 Locate (Name, Host, Tools, Shipped);
               Path : constant String := US.To_String (Where.Path);
               Missing : constant Boolean := Where.Of_Kind = Shipped_Missing;
            begin
               Result.Append
                 (Found_Command'
                    (Name_Length => Name'Length, Path_Length => Path'Length,
                     Name => Name, Path => Path, Is_Shipped => True,
                     Missing => Missing,
                     About => (if Missing then (others => <>)
                               else Describe (Name, Path, True, Tools,
                                              Digest))));
            end;
         end loop;
      end if;
      for Path of Tools.Programs_On_Path (Prefix) loop
         declare
            Slash : constant Natural :=
              Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
            Base : constant String :=
              Path ((if Slash = 0 then Path'First else Slash + 1)
                    .. Path'Last);
            Name : constant String :=
              (if Base'Length > Prefix'Length
                 and then Base (Base'First .. Base'First + Prefix'Length - 1)
                          = Prefix
               then Base (Base'First + Prefix'Length .. Base'Last) else "");
         begin
            if Is_Command_Name (Name)
              and then not Catalogue.Known (Name)
              and then not Shipped.Contains (Name)
            then
               Result.Append
                 (Found_Command'
                    (Name_Length => Name'Length, Path_Length => Path'Length,
                     Name => Name, Path => Path, Is_Shipped => False,
                     Missing => False,
                     About => Describe (Name, Path, False, Tools, Digest)));
            end if;
         end;
      end loop;
      return Result;
   end Scan;

   function Help_Lines (Found : Found_Vectors.Vector) return String is
      Text : US.Unbounded_String;
   begin
      for Item of Found loop
         US.Append (Text, "  " & Item.Name
           & (if Item.Name'Length < 12
              then Ada.Strings.Fixed."*" (12 - Item.Name'Length, ' ')
              else " ")
           & (if Item.Missing
              then "missing: " & (if Item.Path = "" then Prefix & Item.Name
                                  else Item.Path)
              elsif not Item.About.Compatible
              then "incompatible: " & Item.Path & ": "
                   & US.To_String (Item.About.Reason)
              else US.To_String (Item.About.Summary)
                   & (if Item.Is_Shipped then ""
                      else " (" & Item.Path & ")"))
           & LF);
      end loop;
      return US.To_String (Text);
   end Help_Lines;

   function Forwarded_Prefix (Code : String) return String is
      Last_Letter : Natural := Code'First - 1;
   begin
      for Index in Code'Range loop
         exit when Code (Index) not in 'A' .. 'Z';
         Last_Letter := Index;
      end loop;
      if Last_Letter - Code'First + 1 not in 2 .. 8
        or else Last_Letter = Code'Last
        or else (for some Index in Last_Letter + 1 .. Code'Last =>
                   Code (Index) not in '0' .. '9')
      then
         return "";
      end if;
      return Code (Code'First .. Last_Letter);
   end Forwarded_Prefix;

   function Build_Absent_Message return String is
     ("refine has no build command of its own: refine build runs a"
      & " contributed " & Prefix & Build_Name & ", and none is on PATH;"
      & " install one, or compile a program with refine compile");

   function Missing_Message (Name : String; Where : Location) return String
   is
     (if Where.Path = ""
      then "refine " & Name & " is a split command, shipped beside refine"
           & " as " & Prefix & Name & ", but refine could not tell which"
           & " directory it was started from and cannot find it; run refine"
           & " by its full path"
      else "refine " & Name & " is a split command, and this installation"
           & " lacks it: there is no file at " & US.To_String (Where.Path)
           & "; reinstall the release, whose archive carries both, or build"
           & " both from one checkout with ./scripts/build.sh");

   function Incompatible_Message
     (Name : String; Where : Location; About : Description) return String
   is
     (Prefix & Name & " at " & US.To_String (Where.Path)
      & " cannot be run as refine " & Name & ": refine asked it "
      & Prefix & Name & " --describe and " & US.To_String (About.Reason)
      & "; "
      & (if Where.Of_Kind = Shipped
         then "reinstall the release, whose archive carries both, or"
              & " rebuild both from one checkout with ./scripts/build.sh"
         else "update or remove it, or run it by its own name, "
              & Prefix & Name));

end Landin.Commands.External;
