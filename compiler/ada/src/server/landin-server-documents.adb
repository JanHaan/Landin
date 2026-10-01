with Ada.Strings.Fixed;

package body Landin.Server.Documents is

   package Unbounded renames Ada.Strings.Unbounded;

   Hex : constant String := "0123456789ABCDEF";

   function Hex_Value (C : Character) return Integer
     is (case C is
           when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
           when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
           when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
           when others     => -1);

   function Path_Of (URI : String) return String is
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
           or else Path (Path'Last) = '/'
         then
            return "";
         end if;
         return Path;
      end;
   end Path_Of;

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
         if C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' then
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
      Into.Open.Include
        (URI, (URI     => Unbounded.To_Unbounded_String (URI),
               Path    => Unbounded.To_Unbounded_String (Path),
               Version => Version));
      Into.Held.Hold (Path, Text);
   end Open;

   procedure Change
     (Into : in out Store; URI : String; Version : Long_Long_Integer;
      Text : String)
   is
      Held : Document := Into.Open.Element (URI);
   begin
      Held.Version := Version;
      Into.Open.Replace (URI, Held);
      Into.Held.Hold (Unbounded.To_String (Held.Path), Text);
   end Change;

   procedure Close (Into : in out Store; URI : String) is
   begin
      if Into.Open.Contains (URI) then
         Into.Held.Release
           (Unbounded.To_String (Into.Open.Element (URI).Path));
         Into.Open.Delete (URI);
      end if;
   end Close;

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
                 Options => Landin.Platform.No_Arguments);
      end if;
      return (Entry_Directory => Unbounded.Null_Unbounded_String,
              Roots => Landin.Platform.No_Arguments,
              Files => Landin.Platform.Arguments (Path),
              Options => Landin.Platform.No_Arguments);
   end Request_For;

   function Module_Key (From : Store; URI : String) return String
     is (if Rooted (From, URI)
         then Directory_Of (Held_Path (From, URI))
         else Held_Path (From, URI));

   function URI_For (From : Store; Path : String) return String is
   begin
      for Held of From.Open loop
         if Unbounded.To_String (Held.Path) = Path then
            return Unbounded.To_String (Held.URI);
         end if;
      end loop;
      return URI_Of (Path);
   end URI_For;

end Landin.Server.Documents;
