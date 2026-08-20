with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Landin.Diagnostics.Text is

   package Fixed renames Ada.Strings.Fixed;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Source.Byte_Offset;

   LF : constant Character := Character'Val (10);

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
     (Into         : in out Unbounded.Unbounded_String;
      Item         : Label;
      Sources      : Landin.Source.Sets.Source_Set;
      Show_Message : Boolean);

   procedure Render_Label
     (Into         : in out Unbounded.Unbounded_String;
      Item         : Label;
      Sources      : Landin.Source.Sets.Source_Set;
      Show_Message : Boolean)
   is
      use Landin.Source;
   begin
      if not Sources.Contains (Source_Of (Item)) then
         Unbounded.Append (Into, "  --> <unknown source>" & LF);
         return;
      end if;

      --  A label may name a span that does not fit its source: a stage can
      --  be wrong about a byte, and a report that crashes while explaining
      --  an error is worse than the error.  Say so and carry on.
      if not Is_Valid (Sources.Get (Source_Of (Item)), Span_Of (Item)) then
         Unbounded.Append
           (Into,
            "  --> " & Name (Sources.Get (Source_Of (Item)))
            & ": <span outside this source>" & LF);
         return;
      end if;

      declare
         Snap    : constant Snapshot :=
           Sources.Get (Source_Of (Item));
         Where   : constant Span := Span_Of (Item);
         Start   : constant Position := Position_Of (Snap, Where.First);
         Content : constant String := Line_Text (Snap, Start.Line);
         Width   : constant Natural := Gutter_Width (Start.Line);
         Blank   : constant String := Fixed."*" (Width, ' ');
         Column  : constant Natural := Natural (Start.Column);
         Room    : constant Natural :=
           (if Content'Length + 1 > Column
            then Content'Length + 1 - Column
            else 0);
         Carets  : constant Natural :=
           Natural'Min (Natural'Max (Natural (Length (Where)), 1),
                        Natural'Max (Room, 1));
      begin
         Unbounded.Append
           (Into,
            "  --> " & Name (Snap) & ":" & Decimal (Integer (Start.Line))
            & ":" & Decimal (Column) & LF);
         Unbounded.Append (Into, Blank & " |" & LF);
         Unbounded.Append
           (Into,
            Decimal (Integer (Start.Line)) & " | " & Content & LF);
         Unbounded.Append
           (Into,
            Blank & " | " & Fixed."*" (Column - 1, ' ')
            & Fixed."*" (Carets, '^')
            & (if not Show_Message or else Message (Item) = ""
               then "" else " " & Message (Item))
            & LF);
      end;
   end Render_Label;

   function Render
     (Item    : Diagnostic;
      Sources : Landin.Source.Sets.Source_Set) return String
   is
      Buffer : Unbounded.Unbounded_String;
   begin
      Unbounded.Append
        (Buffer,
         Image (Level (Item)) & "[" & Code (Item) & "]: "
         & Message (Primary (Item)) & LF);
      Render_Label (Buffer, Primary (Item), Sources, False);

      for Index in 1 .. Label_Count (Item) loop
         Render_Label
           (Buffer, Nth_Label (Item, Index), Sources, True);
      end loop;

      for Index in 1 .. Note_Count (Item) loop
         Unbounded.Append
           (Buffer, "  = note: " & Nth_Note (Item, Index) & LF);
      end loop;

      return Unbounded.To_String (Buffer);
   end Render;

   function Render
     (List    : Diagnostic_List;
      Sources : Landin.Source.Sets.Source_Set) return String
   is
      Ordered : constant Diagnostic_List := Sorted (List);
      Buffer  : Unbounded.Unbounded_String;
   begin
      for Index in 1 .. Count (Ordered) loop
         Unbounded.Append (Buffer, Render (Get (Ordered, Index), Sources));
      end loop;
      return Unbounded.To_String (Buffer);
   end Render;

end Landin.Diagnostics.Text;
