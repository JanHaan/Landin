with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Landin.Diagnostics.Text is

   package Fixed renames Ada.Strings.Fixed;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Span;

   LF : constant Character := Character'Val (10);

   Truncated : constant String := LF
     & "  = note: diagnostic text truncated at the output limit"
     & LF;

   type Text_Buffer (Limit : Report_Byte_Limit) is record
      Content : Unbounded.Unbounded_String;
      Full    : Boolean := False;
   end record;

   procedure Append (Into : in out Text_Buffer; Text : String);
   function Finish (Buffer : Text_Buffer) return String;

   procedure Append (Into : in out Text_Buffer; Text : String) is
      Room : constant Natural := Into.Limit - Unbounded.Length (Into.Content);
   begin
      if Into.Full then
         return;
      elsif Text'Length <= Room then
         Unbounded.Append (Into.Content, Text);
      else
         if Room > 0 then
            Unbounded.Append
              (Into.Content, Text (Text'First .. Text'First + Room - 1));
         end if;
         Into.Full := True;
      end if;
   end Append;

   function Finish (Buffer : Text_Buffer) return String is
   begin
      if Buffer.Full then
         declare
            Keep : Natural := Buffer.Limit - Truncated'Length;
         begin
            for Step in 1 .. 3 loop
               exit when Keep = 0 or else Character'Pos
                 (Unbounded.Element (Buffer.Content, Keep + 1))
                   not in 128 .. 191;
               Keep := Keep - 1;
            end loop;
            return Unbounded.Slice (Buffer.Content, 1, Keep) & Truncated;
         end;
      end if;
      return Unbounded.To_String (Buffer.Content);
   end Finish;

   function Image (Level : Severity) return String is
     (case Level is
         when Error   => "error",
         when Warning => "warning",
         when Note    => "note");

   --  Decimal image without Ada's leading blank for non-negative values.
   function Decimal (Value : Integer) return String;

   function Decimal (Value : Integer) return String is
      Raw : constant String := Integer'Image (Value);
   begin
      return (if Raw (Raw'First) = ' '
              then Raw (Raw'First + 1 .. Raw'Last)
              else Raw);
   end Decimal;

   --  Source snapshots are arbitrary bytes. An ASCII display makes every
   --  snippet cell deterministic, including tabs, invalid UTF-8 and text
   --  whose terminal width depends on the font or Unicode version.
   function Display_Byte (Value : Character) return String;

   function Display_Byte (Value : Character) return String is
      Hex : constant String := "0123456789ABCDEF";
      Code : constant Natural := Character'Pos (Value);
   begin
      if Value = ASCII.HT then
         return "\t";
      elsif Value in ' ' .. '~' then
         return "" & Value;
      else
         return "\x" & Hex (Code / 16 + 1) & Hex (Code mod 16 + 1);
      end if;
   end Display_Byte;

   function Gutter_Width (Line : Landin.Source.Line_Number) return Natural is
     (Decimal (Integer (Line))'Length);

   ---------------------------------------------------------------------
   --  Render_Label
   --
   --  One label block: the location, the offending line, and a caret run
   --  under the span.  A span that runs past the end of its line is drawn
   --  to the end of that line only; the reader is told where it starts,
   --  and a multi-line ribbon is presentation this stage does not owe.
   ---------------------------------------------------------------------

   procedure Render_Label
     (Into         : in out Text_Buffer;
      Item         : Label;
      Sources      : Landin.Source.Sets.Source_Set;
      Show_Message : Boolean);

   procedure Render_Label
     (Into         : in out Text_Buffer;
      Item         : Label;
      Sources      : Landin.Source.Sets.Source_Set;
      Show_Message : Boolean)
   is
      use Landin.Source;
   begin
      if Into.Full then
         return;
      elsif not Sources.Contains (Source_Of (Item)) then
         Append (Into, "  --> <unknown source>" & LF);
         return;
      end if;

      --  A label may name a span that does not fit its source: a stage can
      --  be wrong about a byte, and a report that crashes while explaining
      --  an error is worse than the error.  Say so and carry on.
      if not Is_Valid (Sources.Get (Source_Of (Item)), Span_Of (Item)) then
         Append (Into, "  --> ");
         Append (Into, Name (Sources.Get (Source_Of (Item))));
         Append (Into, ": <span outside this source>" & LF);
         return;
      end if;

      declare
         Snap : constant Snapshot := Sources.Get (Source_Of (Item));
         Where : constant Span := Span_Of (Item);
         Start : constant Position := Position_Of (Snap, Where.First);
         Line : constant Span := Line_Text_Span (Snap, Start.Line);
         Anchor : constant Byte_Offset := Byte_Offset'Min
           (Where.First, Line.Last);
         First : Byte_Offset :=
           (if Length (Line) > 160 and then Anchor - Line.First > 48
            then Anchor - 48 else Line.First);
         Last : Byte_Offset := First
           + Byte_Offset'Min (160, Line.Last - First);
         Width : constant Natural := Gutter_Width (Start.Line);
         Blank : constant String := Fixed."*" (Width, ' ');

         function Continuation (Offset : Byte_Offset) return Boolean;

         function Continuation (Offset : Byte_Offset) return Boolean is
            Byte : constant String := Slice (Snap, (Offset, Offset + 1));
         begin
            return Character'Pos (Byte (Byte'First)) in 128 .. 191;
         end Continuation;
      begin
         --  Preserve complete UTF-8 sequences at excerpt edges. These two
         --  bounded adjustments do not scan the omitted prefix or suffix.
         for Step in 1 .. 3 loop
            exit when First = Line.First or else not Continuation (First);
            First := First - 1;
         end loop;
         for Step in 1 .. 3 loop
            exit when Last = Line.Last or else not Continuation (Last);
            Last := Last - 1;
         end loop;
         declare
            Content : constant String := Slice (Snap, (First, Last));
            Prefix : constant String :=
              (if First > Line.First then "... " else "");
            Suffix : constant String :=
              (if Last < Line.Last then " ..." else "");
            Before : constant Natural := Natural (Anchor - First);
            Marked : constant Natural := Natural'Min
              (Natural (Length (Where)), Natural (Last - Anchor));
            Column : Natural := Prefix'Length;
            Carets : Natural := 0;
            Display : Unbounded.Unbounded_String;
         begin
            --  The raw excerpt is bounded above. Its escaped display needs
            --  at most four characters per byte; no omitted prefix is read.
            for Index in Content'Range loop
               declare
                  Encoded : constant String := Display_Byte (Content (Index));
                  Offset : constant Natural := Index - Content'First;
               begin
                  Unbounded.Append (Display, Encoded);
                  if Offset < Before then
                     Column := Column + Encoded'Length;
                  elsif Offset - Before < Marked then
                     Carets := Carets + Encoded'Length;
                  end if;
               end;
            end loop;
            Carets := Natural'Max (Carets, 1);
            Append (Into, "  --> ");
            Append (Into, Name (Snap));
            Append
              (Into, ":" & Decimal (Integer (Start.Line)) & ":"
               & Decimal (Integer (Start.Column)) & LF);
            Append (Into, Blank & " |" & LF);
            Append
              (Into, Decimal (Integer (Start.Line)) & " | " & Prefix
               & Unbounded.To_String (Display) & Suffix & LF);
            Append
              (Into, Blank & " | " & Fixed."*" (Column, ' ')
               & Fixed."*" (Carets, '^'));
            if Show_Message and then not Into.Full then
               declare
                  Text : constant String := Message (Item);
               begin
                  if Text /= "" then
                     Append (Into, " ");
                     Append (Into, Text);
                  end if;
               end;
            end if;
            Append (Into, LF & "");
         end;
      end;
   end Render_Label;

   procedure Render_Item
     (Buffer  : in out Text_Buffer;
      Item    : Diagnostic;
      Sources : Landin.Source.Sets.Source_Set);

   procedure Render_Item
     (Buffer  : in out Text_Buffer;
      Item    : Diagnostic;
      Sources : Landin.Source.Sets.Source_Set)
   is
   begin
      Append (Buffer, Image (Level (Item)) & "[" & Code (Item) & "]: ");
      Append (Buffer, Message (Primary (Item)));
      Append (Buffer, LF & "");
      if Buffer.Full then
         return;
      end if;
      --  The first related label can explain the primary span itself.
      --  Render that snippet once, with its label, while retaining the
      --  complete structured report and the order of all related labels.
      if Label_Count (Item) = 0
        or else Source_Of (Nth_Label (Item, 1))
          /= Source_Of (Primary (Item))
        or else Span_Of (Nth_Label (Item, 1)) /= Span_Of (Primary (Item))
      then
         Render_Label (Buffer, Primary (Item), Sources, False);
      end if;

      for Index in 1 .. Label_Count (Item) loop
         exit when Buffer.Full;
         Render_Label
           (Buffer, Nth_Label (Item, Index), Sources, True);
      end loop;

      for Index in 1 .. Note_Count (Item) loop
         exit when Buffer.Full;
         Append (Buffer, "  = note: ");
         Append (Buffer, Nth_Note (Item, Index));
         Append (Buffer, LF & "");
      end loop;
   end Render_Item;

   function Render
     (Item    : Diagnostic;
      Sources : Landin.Source.Sets.Source_Set;
      Byte_Limit : Report_Byte_Limit := Default_Byte_Limit) return String
   is
      Buffer : Text_Buffer (Byte_Limit);
   begin
      Render_Item (Buffer, Item, Sources);
      return Finish (Buffer);
   end Render;

   function Render
     (List    : Diagnostic_List;
      Sources : Landin.Source.Sets.Source_Set;
      Byte_Limit : Report_Byte_Limit := Default_Byte_Limit) return String
   is
      Ordered : constant Diagnostic_List := Sorted (List);
      Buffer  : Text_Buffer (Byte_Limit);
   begin
      for Index in 1 .. Count (Ordered) loop
         exit when Buffer.Full;
         Render_Item (Buffer, Get (Ordered, Index), Sources);
      end loop;
      return Finish (Buffer);
   end Render;

end Landin.Diagnostics.Text;
