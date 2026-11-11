with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Landin.Testing.Reports is

   package Unbounded renames Ada.Strings.Unbounded;

   package Segment_Lists is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   LF : constant Character := ASCII.LF;

   Arrow : constant String := "  --> ";

   function Lexical (Path : String) return String is
      Absolute : constant Boolean :=
        Path'Length > 0 and then Path (Path'First) = '/';
      Kept : Segment_Lists.Vector;
      First : Integer := Path'First;
      Result : Unbounded.Unbounded_String;
   begin
      for Index in Path'First .. Path'Last + 1 loop
         if Index > Path'Last or else Path (Index) = '/' then
            declare
               Segment : constant String := Path (First .. Index - 1);
            begin
               if Segment = "" or else Segment = "." then
                  null;
               elsif Segment = ".." then
                  if not Kept.Is_Empty and then Kept.Last_Element /= ".."
                  then
                     Kept.Delete_Last;
                  elsif not Absolute then
                     Kept.Append (Segment);
                  end if;
               else
                  Kept.Append (Segment);
               end if;
            end;
            First := Index + 1;
         end if;
      end loop;
      for Segment of Kept loop
         if Unbounded.Length (Result) > 0 then
            Unbounded.Append (Result, "/");
         end if;
         Unbounded.Append (Result, Segment);
      end loop;
      if Absolute then
         return "/" & Unbounded.To_String (Result);
      elsif Unbounded.Length (Result) = 0 then
         return ".";
      end if;
      return Unbounded.To_String (Result);
   end Lexical;

   function Is_Below (Path, Directory : String) return Boolean is
      Within : constant String := Lexical (Path);
      Base : constant String := Lexical (Directory);
   begin
      if Base = "." then
         return Within /= "." and then Within (Within'First) /= '/'
           and then Within /= ".."
           and then not (Within'Length >= 3
                         and then Within (Within'First .. Within'First + 2)
                           = "../");
      end if;
      return Within'Length > Base'Length + 1
        and then Within (Within'First .. Within'First + Base'Length - 1)
          = Base
        and then Within (Within'First + Base'Length) = '/';
   end Is_Below;

   function Recorded_Form (Report, Directory : String) return String is
      Result : Unbounded.Unbounded_String;

      --  The library location whose block is being rewritten: its line
      --  number as printed, and which of the block's three lines after
      --  the location comes next, 0 when none is.
      Number : Unbounded.Unbounded_String;
      Stage  : Natural := 0;

      function All_Digits (Text : String) return Boolean
        is (Text'Length > 0
            and then (for all C of Text => C in '0' .. '9'));

      function Starts (Text, Prefix : String) return Boolean
        is (Text'Length >= Prefix'Length
            and then Text (Text'First .. Text'First + Prefix'Length - 1)
              = Prefix);

      --  The line's text in its recorded form, the block's state moved on.
      function Rewritten (Line : String) return String;

      function Rewritten (Line : String) return String is
         Width : constant Natural := Unbounded.Length (Number);
         Blank : constant String := Ada.Strings.Fixed."*" (Width, ' ');
         Marker_Blank : constant String :=
           Ada.Strings.Fixed."*" (Library_Line'Length, ' ');
         Printed : constant String := Unbounded.To_String (Number);
      begin
         if Stage = 1 and then Line = Blank & " |" then
            Stage := 2;
            return Marker_Blank & " |";
         elsif Stage = 2 and then Starts (Line, Printed & " |") then
            Stage := 3;
            return Library_Line & Line (Line'First + Width .. Line'Last);
         elsif Stage = 3 and then Starts (Line, Blank & " |") then
            Stage := 0;
            return Marker_Blank & Line (Line'First + Width .. Line'Last);
         end if;
         Stage := 0;

         --  A location line: the arrow, a name, `:LINE:COLUMN`.
         if not Starts (Line, Arrow) then
            return Line;
         end if;
         declare
            Last_Colon : constant Natural := Ada.Strings.Fixed.Index
              (Line, ":", Ada.Strings.Backward);
            Line_Colon : constant Natural :=
              (if Last_Colon > Line'First
               then Ada.Strings.Fixed.Index
                 (Line (Line'First .. Last_Colon - 1), ":",
                  Ada.Strings.Backward)
               else 0);
         begin
            if Line_Colon <= Line'First + Arrow'Length
              or else not All_Digits (Line (Line_Colon + 1 .. Last_Colon - 1))
              or else not All_Digits (Line (Last_Colon + 1 .. Line'Last))
              or else Is_Below
                (Line (Line'First + Arrow'Length .. Line_Colon - 1),
                 Directory)
            then
               return Line;
            end if;
            Number := Unbounded.To_Unbounded_String
              (Line (Line_Colon + 1 .. Last_Colon - 1));
            Stage := 1;
            return Line (Line'First .. Line_Colon) & Library_Line
              & Line (Last_Colon .. Line'Last);
         end;
      end Rewritten;

      First : Integer := Report'First;
   begin
      for Index in Report'First .. Report'Last loop
         if Report (Index) = LF then
            Unbounded.Append (Result, Rewritten (Report (First .. Index - 1)));
            Unbounded.Append (Result, LF);
            First := Index + 1;
         end if;
      end loop;
      if First <= Report'Last then
         Unbounded.Append (Result, Rewritten (Report (First .. Report'Last)));
      end if;
      return Unbounded.To_String (Result);
   end Recorded_Form;

end Landin.Testing.Reports;
