with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;

with Landin.Platform;
with Landin.Platform.Native;
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
   procedure Load_Tree
     (Real           : Landin.Platform.Native.Native_Filesystem;
      Host           : in out Landin.Testing.Fakes.Fake_Filesystem;
      Real_Directory : String;
      Fake_Directory : String);

   procedure Load_Tree
     (Real           : Landin.Platform.Native.Native_Filesystem;
      Host           : in out Landin.Testing.Fakes.Fake_Filesystem;
      Real_Directory : String;
      Fake_Directory : String)
   is
      Entries : Landin.Platform.Path_List;
      Listed  : Landin.Platform.List_Status;
   begin
      Host.Add_Directory (Fake_Directory);
      Real.List_Directory (Real_Directory, Entries, Listed);
      if Listed /= Landin.Platform.List_Ok then
         return;
      end if;
      for Name of Entries loop
         declare
            From : constant String := Real_Directory & "/" & Name;
            To   : constant String := Fake_Directory & "/" & Name;
         begin
            if Real.Is_Directory (From) then
               Load_Tree (Real, Host, From, To);
            else
               declare
                  Content : Unbounded.Unbounded_String;
                  Read    : Landin.Platform.Read_Status;
               begin
                  Real.Read_File (From, Content, Read);
                  if Read = Landin.Platform.Read_Ok then
                     Host.Add_File (To, Unbounded.To_String (Content));
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
   begin
      Real.Read_File (Directory & "/session.lsp", Content, Read);
      if Read /= Landin.Platform.Read_Ok then
         Problem ("session.lsp is unreadable");
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
            Problem ("session.lsp does not end in a line end");
            return Answer;
         end if;
      end;

      if Real.Is_Directory (Directory & "/workspace") then
         Load_Tree (Real, Host, Directory & "/workspace", "/workspace");
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
            Pauses.Append (Unbounded.Length (Script));
         elsif Line'Length > 0 and then not Starts (Line, "#") then
            Problem ("session.lsp has a line that is none of its forms: "
                     & Line);
            return Answer;
         end if;
      end loop;
      if Wanted < 0 then
         Problem ("session.lsp names no exit status");
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

end Landin.Testing.Sessions;
