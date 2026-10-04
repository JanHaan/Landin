with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

package body Landin.Server.Documents is

   package Unbounded renames Ada.Strings.Unbounded;

   procedure Free is new Ada.Unchecked_Deallocation
     (Landin.Server.Texts.Buffer, Buffer_Access);

   Hex : constant String := "0123456789ABCDEF";

   function Hex_Value (C : Character) return Integer
     is (case C is
           when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
           when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
           when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
           when others     => -1);

   function Decode_Path (URI : String; Root : Boolean) return String;

   function Decode_Path (URI : String; Root : Boolean) return String is
      Scheme : constant String := "file://";
      Result : Unbounded.Unbounded_String;
      Index  : Natural;
   begin
      if URI'Length <= Scheme'Length
        or else URI (URI'First .. URI'First + Scheme'Length - 1) /= Scheme
      then
         return "";
      end if;
      Index := URI'First + Scheme'Length;
      --  An authority other than the empty one or localhost is another
      --  machine's file.
      if URI (Index) /= '/' then
         declare
            Slash : constant Natural :=
              Ada.Strings.Fixed.Index (URI (Index .. URI'Last), "/");
         begin
            if Slash = 0 or else URI (Index .. Slash - 1) /= "localhost" then
               return "";
            end if;
            Index := Slash;
         end;
      end if;
      while Index <= URI'Last loop
         if URI (Index) in '?' | '#' then
            return "";
         elsif URI (Index) = '%' then
            if Index + 2 > URI'Last
              or else Hex_Value (URI (Index + 1)) < 0
              or else Hex_Value (URI (Index + 2)) < 0
            then
               return "";
            end if;
            Unbounded.Append
              (Result, Character'Val
                 (Hex_Value (URI (Index + 1)) * 16
                  + Hex_Value (URI (Index + 2))));
            Index := Index + 3;
         else
            Unbounded.Append (Result, URI (Index));
            Index := Index + 1;
         end if;
      end loop;
      declare
         Path : constant String := Unbounded.To_String (Result);
      begin
         if Ada.Strings.Fixed.Index (Path, [1 => ASCII.NUL]) > 0
           or else Ada.Strings.Fixed.Index (Path & "/", "/../") > 0
           or else Ada.Strings.Fixed.Index (Path & "/", "/./") > 0
         then
            return "";
         end if;
         if Root then
            declare
               Last : Natural := Path'Last;
            begin
               while Last > Path'First and then Path (Last) = '/' loop
                  Last := Last - 1;
               end loop;
               return Path (Path'First .. Last);
            end;
         elsif Path (Path'Last) = '/' then
            return "";
         end if;
         return Path;
      end;
   end Decode_Path;

   function Path_Of (URI : String) return String
     is (Decode_Path (URI, Root => False));

   function Root_Path_Of (URI : String) return String
     is (Decode_Path (URI, Root => True));

   function URI_Of (Path : String) return String is
      Result : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String ("file://");
   begin
      for C of Path loop
         if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                | '-' | '.' | '_' | '~' | '/'
         then
            Unbounded.Append (Result, C);
         else
            Unbounded.Append
              (Result, "%" & Hex (Character'Pos (C) / 16 + 1)
                       & Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return Unbounded.To_String (Result);
   end URI_Of;

   --  Where an untitled buffer is held: a directory no host has, and a
   --  name the URI decides, so two untitled buffers never meet.
   Untitled : constant String := "/.landin-untitled/";

   function Untitled_Path (URI : String) return String is
      Name : Unbounded.Unbounded_String;
   begin
      for C of URI loop
         --  '_' starts an escaped byte, so a literal one must be escaped
         --  too; otherwise distinct URIs can name the same held path.
         if C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' then
            Unbounded.Append (Name, C);
         else
            Unbounded.Append
              (Name, "_" & Hex (Character'Pos (C) / 16 + 1)
                     & Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return Untitled & Unbounded.To_String (Name) & ".ldn";
   end Untitled_Path;

   procedure Open
     (Into : in out Store; URI : String; Version : Long_Long_Integer;
      Text : String)
   is
      Named : constant String := Path_Of (URI);
      Path  : constant String :=
        (if Named /= "" then Named else Untitled_Path (URI));
   begin
      declare
         Previous : Buffer_Access :=
           (if Into.Open.Contains (URI) then Into.Open.Element (URI).Data
            else null);
         Data : Buffer_Access := new Landin.Server.Texts.Buffer;
      begin
         begin
            Landin.Server.Texts.Open (Data.all, Text);
            Into.Open.Include
              (URI, (URI     => Unbounded.To_Unbounded_String (URI),
                     Path    => Unbounded.To_Unbounded_String (Path),
                     Version => Version, Data => Data));
         exception
            when others =>
               Free (Data);
               raise;
         end;
         Free (Previous);
      end;
      Into.Held.Hold (Path, Text);
   end Open;

   --  The held copy of a document about to change is out of date and is
   --  read by nothing before Flush holds the new text, so let it go now
   --  rather than keep a whole superseded source through a burst.  The
   --  path stays held, empty, so it is still listed in its directory.
   procedure Unhold (Into : in out Store; URI : String);

   procedure Unhold (Into : in out Store; URI : String) is
      Held : constant Document := Into.Open.Element (URI);
   begin
      if not Landin.Server.Texts.Is_Dirty (Held.Data.all) then
         Into.Held.Hold (Unbounded.To_String (Held.Path), "");
      end if;
   end Unhold;

   procedure Change
     (Into : in out Store; URI : String; Text : String) is
   begin
      Unhold (Into, URI);
      Landin.Server.Texts.Replace (Into.Open.Element (URI).Data.all, Text);
   end Change;

   procedure Edit
     (Into : in out Store; URI : String;
      First, Last : Landin.Server.Positions.Position;
      Unit : Landin.Server.Positions.Encoding; Text : String) is
   begin
      Unhold (Into, URI);
      Landin.Server.Texts.Edit
        (Into.Open.Element (URI).Data.all, First, Last, Unit, Text);
   end Edit;

   procedure Set_Version
     (Into : in out Store; URI : String; Version : Long_Long_Integer)
   is
      Held : Document := Into.Open.Element (URI);
   begin
      Held.Version := Version;
      Into.Open.Replace (URI, Held);
   end Set_Version;

   procedure Flush (Into : in out Store) is
   begin
      for Held of Into.Open loop
         if Landin.Server.Texts.Is_Dirty (Held.Data.all) then
            declare
               Text : constant String :=
                 Landin.Server.Texts.Content (Held.Data.all);
            begin
               Into.Held.Hold (Unbounded.To_String (Held.Path), Text);
               --  Analysis already paid to assemble the source.  One slice
               --  of it makes the next edit's walk short again.
               Landin.Server.Texts.Open (Held.Data.all, Text);
            end;
         end if;
      end loop;
   end Flush;

   procedure Close (Into : in out Store; URI : String) is
   begin
      if Into.Open.Contains (URI) then
         declare
            Data : Buffer_Access := Into.Open.Element (URI).Data;
            Path : constant String :=
              Unbounded.To_String (Into.Open.Element (URI).Path);
         begin
            Free (Data);
            Into.Open.Delete (URI);
            if Unbounded.To_String (Into.Active_URI) = URI then
               Into.Active_URI := Unbounded.Null_Unbounded_String;
            end if;
            Into.Held.Release (Path);
            for Held of Into.Open loop
               if Unbounded.To_String (Held.Path) = Path then
                  Into.Held.Hold
                    (Path, Landin.Server.Texts.Content (Held.Data.all));
                  exit;
               end if;
            end loop;
         end;
      end if;
   end Close;

   procedure Activate
     (Into : in out Store; URI : String; Changed : out Boolean) is
      Held : constant Document := Into.Open.Element (URI);
      Text : constant String := Landin.Server.Texts.Content (Held.Data.all);
      Previous : Unbounded.Unbounded_String;
      Status : Landin.Platform.Read_Status;
   begin
      Into.Held.Read_File
        (Unbounded.To_String (Held.Path), Previous, Status);
      Changed := Unbounded.To_String (Previous) /= Text;
      Into.Held.Hold
        (Unbounded.To_String (Held.Path), Text);
      Into.Active_URI := Unbounded.To_Unbounded_String (URI);
   end Activate;

   overriding procedure Finalize (Into : in out Store) is
   begin
      for Held of Into.Open loop
         declare
            Data : Buffer_Access := Held.Data;
         begin
            Free (Data);
         end;
      end loop;
   end Finalize;

   function Is_Open (From : Store; URI : String) return Boolean
     is (From.Open.Contains (URI));

   function Held_Path (From : Store; URI : String) return String
     is (Unbounded.To_String (From.Open.Element (URI).Path));

   --  The directory a held path is in, or "" for an untitled buffer or a
   --  path at the top of the filesystem.
   function Directory_Of (Path : String) return String;

   function Directory_Of (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      if Slash <= Path'First
        or else (Path'Length >= Untitled'Length
                 and then Path (Path'First .. Path'First + Untitled'Length - 1)
                   = Untitled)
      then
         return "";
      end if;
      return Path (Path'First .. Slash - 1);
   end Directory_Of;

   function Rooted (From : Store; URI : String) return Boolean
     is (not From.Roots.Is_Empty
         and then Directory_Of (Held_Path (From, URI)) /= "");

   function Request_For (From : Store; URI : String)
     return Landin.Server.Analysis.Request
   is
      Path : constant String := Held_Path (From, URI);
   begin
      if Rooted (From, URI) then
         return (Entry_Directory =>
                   Unbounded.To_Unbounded_String (Directory_Of (Path)),
                 Roots => From.Roots,
                 Files => Landin.Platform.No_Arguments,
                 Options => Landin.Platform.No_Arguments,
                 Firmware_Entry => Unbounded.Null_Unbounded_String);
      end if;
      return (Entry_Directory => Unbounded.Null_Unbounded_String,
              Roots => Landin.Platform.No_Arguments,
              Files => Landin.Platform.Arguments (Path),
              Options => Landin.Platform.No_Arguments,
              Firmware_Entry => Unbounded.Null_Unbounded_String);
   end Request_For;

   function Module_Key (From : Store; URI : String) return String
     is (if Rooted (From, URI)
         then Directory_Of (Held_Path (From, URI))
         else Held_Path (From, URI));

   function URI_For
     (From : Store; Path : String; Preferred : String := "") return String
   is
      Chosen : constant String :=
        (if Preferred /= "" then Preferred
         else Unbounded.To_String (From.Active_URI));
   begin
      if From.Open.Contains (Chosen)
        and then Unbounded.To_String (From.Open.Element (Chosen).Path) = Path
      then
         return Chosen;
      end if;
      for Held of From.Open loop
         if Unbounded.To_String (Held.Path) = Path then
            return Unbounded.To_String (Held.URI);
         end if;
      end loop;
      return URI_Of (Path);
   end URI_For;

end Landin.Server.Documents;
