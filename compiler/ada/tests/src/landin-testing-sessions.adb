with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;

with Landin.Platform.Native;
with Landin.Server.Documents;
with Landin.Server.Sessions;
with Landin.Server.Transport;
with Landin.Testing.Fakes;

package body Landin.Testing.Sessions is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;

   package Line_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   package Offset_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Natural);

   LF : constant Character := ASCII.LF;

   function Starts (Text, Prefix : String) return Boolean
     is (Text'Length >= Prefix'Length
         and then Text (Text'First .. Text'First + Prefix'Length - 1)
           = Prefix);

   function After (Text, Prefix : String) return String
     is (Text (Text'First + Prefix'Length .. Text'Last));

   --  `\r` and `\n` as CR and LF, `\\` as one backslash.
   function Unescaped (Text : String) return String;

   function Unescaped (Text : String) return String is
      Result : Unbounded.Unbounded_String;
      Index  : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         if Text (Index) = '\' and then Index < Text'Last then
            case Text (Index + 1) is
               when 'r' => Unbounded.Append (Result, ASCII.CR);
               when 'n' => Unbounded.Append (Result, ASCII.LF);
               when others => Unbounded.Append (Result, Text (Index + 1));
            end case;
            Index := Index + 2;
         else
            Unbounded.Append (Result, Text (Index));
            Index := Index + 1;
         end if;
      end loop;
      return Unbounded.To_String (Result);
   end Unescaped;

   --  Every file under Real_Directory, added to Host under Fake_Directory.
   --  Unread names the first directory or file that could not be read,
   --  and stays empty when the whole tree was loaded: a session run
   --  against less than its tree is not the session in the repository.
   --  Hollow names, as Fake_Directory spells it, the first directory that
   --  holds nothing: Git keeps no empty directory, so a session that
   --  needs one passes where it was written and is another session in
   --  every clone.
   procedure Load_Tree
     (Real           : Landin.Platform.Native.Native_Filesystem;
      Host           : in out Landin.Testing.Fakes.Fake_Filesystem;
      Real_Directory : String;
      Fake_Directory : String;
      Unread         : in out Unbounded.Unbounded_String;
      Hollow         : in out Unbounded.Unbounded_String);

   procedure Load_Tree
     (Real           : Landin.Platform.Native.Native_Filesystem;
      Host           : in out Landin.Testing.Fakes.Fake_Filesystem;
      Real_Directory : String;
      Fake_Directory : String;
      Unread         : in out Unbounded.Unbounded_String;
      Hollow         : in out Unbounded.Unbounded_String)
   is
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;

      procedure Note (Path : String);

      procedure Note (Path : String) is
      begin
         if Unbounded.Length (Unread) = 0 then
            Unread := Unbounded.To_Unbounded_String (Path);
         end if;
      end Note;
   begin
      Host.Add_Directory (Fake_Directory);
      Real.List_Directory (Real_Directory, Entries, Listed);
      if Listed /= Landin.Platform.List_Ok then
         Note (Real_Directory);
         return;
      end if;
      if Entries.Is_Empty and then Unbounded.Length (Hollow) = 0 then
         Hollow := Unbounded.To_Unbounded_String (Fake_Directory);
      end if;
      for Name of Entries loop
         declare
            From : constant String := Real_Directory & "/" & Name;
            To   : constant String := Fake_Directory & "/" & Name;
         begin
            if Real.Is_Directory (From) then
               Load_Tree (Real, Host, From, To, Unread, Hollow);
            else
               declare
                  Content : Unbounded.Unbounded_String;
                  Read    : Landin.Platform.Read_Status;
               begin
                  Real.Read_File (From, Content, Read);
                  if Read = Landin.Platform.Read_Ok then
                     Host.Add_File (To, Unbounded.To_String (Content));
                  else
                     Note (From);
                  end if;
               end;
            end if;
         end;
      end loop;
   end Load_Tree;

   --  Each framed message in Output, in order.
   function Messages (Output : String) return Line_Vectors.Vector;

   function Messages (Output : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      Index  : Natural := Output'First;
   begin
      while Index <= Output'Last loop
         declare
            Blank : constant Natural := Ada.Strings.Fixed.Index
              (Output (Index .. Output'Last), ASCII.CR & LF & ASCII.CR & LF);
            Colon : constant Natural := Ada.Strings.Fixed.Index
              (Output (Index .. Output'Last), ":");
         begin
            exit when Blank = 0 or else Colon = 0 or else Colon > Blank;
            declare
               Length : constant Natural := Natural'Value
                 (Output (Colon + 1 .. Blank - 1));
               First  : constant Positive := Blank + 4;
            begin
               Result.Append (Output (First .. First + Length - 1));
               Index := First + Length;
            end;
         end;
      end loop;
      return Result;
   end Messages;

   function Run
     (Directory : String; Include_Navigation : Boolean := True)
     return Outcome is
      Real     : Landin.Platform.Native.Native_Filesystem;
      Host     : aliased Landin.Testing.Fakes.Fake_Filesystem;
      Channel  : Landin.Testing.Fakes.Fake_Channel;
      Answer   : Outcome;
      Script   : Unbounded.Unbounded_String;
      Lines    : Line_Vectors.Vector;
      Expected : Line_Vectors.Vector;
      Wanted   : Integer := -1;
      Chunk    : Positive := 4096;
      Content  : Unbounded.Unbounded_String;
      Read     : Landin.Platform.Read_Status;
      Pauses   : Offset_Vectors.Vector;
      Last_Pause : Natural := 0;
      Has_Pause : Boolean := False;

      procedure Count_Analysis;

      procedure Count_Analysis is
      begin
         Answer.Analyses := Answer.Analyses + 1;
      end Count_Analysis;

      procedure Problem (Text : String);

      procedure Problem (Text : String) is
      begin
         if Unbounded.Length (Answer.Problem) = 0 then
            Answer.Problem := Unbounded.To_Unbounded_String (Text);
         end if;
      end Problem;

      --  The session cannot be run as written; nothing is recorded.
      procedure Malformed (Text : String);

      procedure Malformed (Text : String) is
      begin
         Problem (Text);
         Answer.Malformed := True;
         Answer.Recorded := Unbounded.Null_Unbounded_String;
      end Malformed;

      Unread : Unbounded.Unbounded_String;
      Hollow : Unbounded.Unbounded_String;

      --  The file to add to the empty directory the fake host has at
      --  Held: the first one there that the transcript names in a URI, or
      --  any file when it names none.
      function File_To_Add (Held : String) return String;

      function File_To_Add (Held : String) return String is
         Library : constant String := "/opt/landin/lib/landin";
         Beside  : constant String :=
           (if Starts (Held, Library)
            then "library" & Held (Held'First + Library'Length .. Held'Last)
            else Held (Held'First + 1 .. Held'Last));
         Wanted  : constant String := "file://" & Held & "/";
      begin
         for Line of Lines loop
            declare
               At_URI : constant Natural :=
                 Ada.Strings.Fixed.Index (Line, Wanted);
               Last   : Natural;
            begin
               if At_URI > 0 then
                  Last := At_URI + Wanted'Length;
                  while Last <= Line'Last
                    and then Line (Last) not in '"' | '/' | ' '
                  loop
                     Last := Last + 1;
                  end loop;
                  if Last > At_URI + Wanted'Length
                    and then Last <= Line'Last
                    and then Line (Last) = '"'
                  then
                     return Directory & "/" & Beside & "/"
                       & Line (At_URI + Wanted'Length .. Last - 1)
                       & ", which the transcript names";
                  end if;
               end if;
            end;
         end loop;
         return "a file in " & Directory & "/" & Beside;
      end File_To_Add;
   begin
      Real.Read_File (Directory & "/session.lsp", Content, Read);
      if Read /= Landin.Platform.Read_Ok then
         Malformed ("session.lsp is unreadable");
         return Answer;
      end if;
      declare
         Text  : constant String := Unbounded.To_String (Content);
         First : Positive := Text'First;
      begin
         for Index in Text'Range loop
            if Text (Index) = LF then
               Lines.Append (Text (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;
         if First <= Text'Last then
            Malformed ("session.lsp does not end in a line end");
            return Answer;
         end if;
      end;

      if Real.Is_Directory (Directory & "/workspace") then
         Load_Tree (Real, Host, Directory & "/workspace", "/workspace",
                    Unread, Hollow);
      end if;
      --  A server finds its library beside itself, and a Cortex-M module
      --  that imports no description reaches the library's reference
      --  (D543), so a session holds the server to not publishing it.
      Host.Add_Firmware_Library;
      --  A session's own library modules, beside the reference, for one
      --  that needs `core` without the whole of it.
      if Real.Is_Directory (Directory & "/library") then
         Load_Tree (Real, Host, Directory & "/library",
                    "/opt/landin/lib/landin", Unread, Hollow);
      end if;
      if Unbounded.Length (Unread) > 0 then
         Malformed ("the session's tree could not be read whole: "
                    & Unbounded.To_String (Unread) & " is unreadable");
         return Answer;
      end if;
      if Unbounded.Length (Hollow) > 0 then
         Malformed ("the session's tree holds an empty directory, served"
                    & " as " & Unbounded.To_String (Hollow) & ", which Git"
                    & " does not keep, so the session differs in a clone:"
                    & " add "
                    & File_To_Add (Unbounded.To_String (Hollow))
                    & ", or remove the directory");
         return Answer;
      end if;

      for Line of Lines loop
         if Starts (Line, "-> ")
           and then not Include_Navigation
           and then (Ada.Strings.Fixed.Index
             (Line, """method"":""textDocument/hover""") > 0
             or else Ada.Strings.Fixed.Index
               (Line, """method"":""textDocument/definition""") > 0
             or else Ada.Strings.Fixed.Index
               (Line, """method"":""textDocument/codeAction""") > 0)
         then
            null;
         elsif Starts (Line, "-> ") then
            Unbounded.Append
              (Script, Landin.Server.Transport.Framed (After (Line, "-> ")));
         elsif Starts (Line, "raw: ") then
            Unbounded.Append (Script, Unescaped (After (Line, "raw: ")));
         elsif Starts (Line, "<- ") then
            Expected.Append (After (Line, "<- "));
         elsif Starts (Line, "exit: ") then
            Wanted := Integer'Value (After (Line, "exit: "));
         elsif Starts (Line, "chunk: ") then
            Chunk := Positive'Value (After (Line, "chunk: "));
         elsif Line = "pause" then
            Last_Pause := Unbounded.Length (Script);
            Has_Pause := True;
            Pauses.Append (Last_Pause);
         elsif Starts (Line, "disk: ") then
            declare
               Split : constant Natural := Ada.Strings.Fixed.Index
                 (Line, " | ");
            begin
               if not Has_Pause or else Split = 0 then
                  Malformed ("disk edit needs a preceding pause: " & Line);
                  return Answer;
               end if;
               declare
                  Path : constant String := Landin.Server.Documents.Path_Of
                    (Line (Line'First + 6 .. Split - 1));
               begin
                  if Path = "" then
                     Malformed ("disk edit needs a file URI: " & Line);
                     return Answer;
                  end if;
                  Landin.Testing.Fakes.Edit_At
                    (Channel, Last_Pause, Host'Unchecked_Access, Path,
                     Unescaped (Line (Split + 3 .. Line'Last)));
               end;
            end;
         elsif Starts (Line, "gone: ") then
            declare
               Path : constant String := Landin.Server.Documents.Root_Path_Of
                 (After (Line, "gone: "));
            begin
               if not Has_Pause or else Path = "" then
                  Problem ("a removal needs a preceding pause and a file"
                           & " URI: " & Line);
                  return Answer;
               end if;
               Landin.Testing.Fakes.Remove_At
                 (Channel, Last_Pause, Host'Unchecked_Access, Path);
            end;
         elsif Starts (Line, "link: ") then
            declare
               Split : constant Natural := Ada.Strings.Fixed.Index
                 (Line, " | ");
               Path : constant String :=
                 (if Split = 0 then ""
                  else Landin.Server.Documents.Path_Of
                    (Line (Line'First + 6 .. Split - 1)));
               Target : constant String :=
                 (if Split = 0 then ""
                  else Landin.Server.Documents.Path_Of
                    (Line (Split + 3 .. Line'Last)));
            begin
               if Path = "" or else Target = "" then
                  Problem ("a link needs two file URIs: " & Line);
                  return Answer;
               end if;
               for Index in Path'First + 1 .. Path'Last loop
                  if Path (Index) = '/'
                    and then not Host.Is_Directory
                      (Path (Path'First .. Index - 1))
                  then
                     Host.Add_Directory (Path (Path'First .. Index - 1));
                  end if;
               end loop;
               Host.Add_Symbolic_Link (Path, Target);
            end;
         elsif Line'Length > 0 and then not Starts (Line, "#") then
            Malformed ("session.lsp has a line that is none of its forms: "
                       & Line);
            return Answer;
         end if;
      end loop;
      if Wanted < 0 then
         Malformed ("session.lsp names no exit status");
         return Answer;
      end if;

      Channel.Script_Unbounded (Script, Chunk);
      for Offset of Pauses loop
         Channel.Pause_At (Offset);
      end loop;
      declare
         Status : Landin.Server.Sessions.Exit_Status;
      begin
         Landin.Server.Sessions.Serve
           (Channel, Host'Unchecked_Access, Status,
            On_Analysis => Count_Analysis'Access);
         Answer.Log := Unbounded.To_Unbounded_String
           (Landin.Testing.Fakes.Logged (Channel));
         Answer.Wanted_Exit := Wanted;
         Answer.Ended_With := Integer (Status);
         declare
            Sent : constant Line_Vectors.Vector :=
              Messages (Landin.Testing.Fakes.Output (Channel));
            Next : Positive := 1;
         begin
            --  The transcript as it would be recorded: each `<-` line in
            --  place, replaced by what was sent, the rest after the last.
            for Line of Lines loop
               if Starts (Line, "<- ") then
                  if Next <= Natural (Sent.Length) then
                     Unbounded.Append
                       (Answer.Recorded, "<- " & Sent.Element (Next) & LF);
                     Next := Next + 1;
                  end if;
               elsif Starts (Line, "exit: ") then
                  while Next <= Natural (Sent.Length) loop
                     Unbounded.Append
                       (Answer.Recorded, "<- " & Sent.Element (Next) & LF);
                     Next := Next + 1;
                  end loop;
                  Unbounded.Append
                    (Answer.Recorded, "exit:" & Natural'Image (Status) & LF);
               else
                  Unbounded.Append (Answer.Recorded, Line & LF);
               end if;
            end loop;

            for Index in 1 .. Natural'Max
              (Natural (Sent.Length), Natural (Expected.Length))
            loop
               if Index > Natural (Sent.Length) then
                  Problem ("message" & Index'Image & " was never sent: "
                           & Expected.Element (Index));
               elsif Index > Natural (Expected.Length) then
                  Problem ("message" & Index'Image & " was not expected: "
                           & Sent.Element (Index));
               elsif Sent.Element (Index) /= Expected.Element (Index) then
                  Problem ("message" & Index'Image & " differs:" & LF
                           & "  expected " & Expected.Element (Index) & LF
                           & "  sent     " & Sent.Element (Index));
               end if;
            end loop;
            if Status /= Wanted then
               Problem ("the session ended with" & Status'Image
                        & " and not" & Wanted'Image);
            end if;
         end;
      end;
      return Answer;
   end Run;

   procedure Inventory
     (Root    : String;
      Names   : out Landin.Platform.Path_List;
      Problem : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Real    : Landin.Platform.Native.Native_Filesystem;
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
   begin
      Names.Clear;
      Problem := Unbounded.Null_Unbounded_String;
      Real.List_Directory (Root, Entries, Listed);
      if Listed /= Landin.Platform.List_Ok then
         Problem := Unbounded.To_Unbounded_String
           (Root & " cannot be listed, so no session in it is run");
         return;
      end if;
      for Name of Entries loop
         if Name'Length > 0 and then Name (Name'First) not in '.' | '_'
           and then Real.Is_Directory (Root & "/" & Name)
         then
            if Real.Exists (Root & "/" & Name & "/session.lsp") then
               Names.Append (Name);
            else
               if Unbounded.Length (Problem) > 0 then
                  Unbounded.Append (Problem, "; ");
               end if;
               Unbounded.Append
                 (Problem, Root & "/" & Name & " holds no session.lsp, so"
                  & " the session is not run");
            end if;
         end if;
      end loop;
   end Inventory;

end Landin.Testing.Sessions;
