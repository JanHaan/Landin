with Landin.Provenance;
with Landin.Source.Sets;

package body Landin.Tests.Source_Suite is

   use Landin.Source;

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   procedure Empty_Text_Has_One_Line (Item : in out Landin.Testing.Context);

   procedure Empty_Text_Has_One_Line (Item : in out Landin.Testing.Context) is
      Snap : constant Snapshot := Create (1, "empty.ldn", "");
   begin
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Snap)), 1, "empty text has one line");
      Landin.Testing.Check_Equal
        (Item, Natural (Length (Snap)), 0, "empty text has no bytes");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Snap, 1), "", "the only line is empty");
   end Empty_Text_Has_One_Line;

   procedure Line_Feed_Maps_Lines (Item : in out Landin.Testing.Context);

   procedure Line_Feed_Maps_Lines (Item : in out Landin.Testing.Context) is
      Snap : constant Snapshot :=
        Create (1, "three.ldn", "one" & LF & "two" & LF & "three");
   begin
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Snap)), 3, "three lines");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Snap, 1), "one", "first line");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Snap, 2), "two", "second line");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Snap, 3), "three", "third line");
   end Line_Feed_Maps_Lines;

   procedure Trailing_Terminator_Adds_A_Line
     (Item : in out Landin.Testing.Context);

   procedure Trailing_Terminator_Adds_A_Line
     (Item : in out Landin.Testing.Context)
   is
      Snap  : constant Snapshot := Create (1, "t.ldn", "a" & LF);
      Where : constant Position := Position_Of (Snap, Length (Snap));
   begin
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Snap)), 2,
         "text ending in a terminator has a final empty line");
      Landin.Testing.Check_Equal
        (Item, Natural (Where.Line), 2, "one past the end is on line two");
      Landin.Testing.Check_Equal
        (Item, Natural (Where.Column), 1, "one past the end is at column one");
   end Trailing_Terminator_Adds_A_Line;

   procedure Carriage_Returns_Terminate
     (Item : in out Landin.Testing.Context);

   procedure Carriage_Returns_Terminate
     (Item : in out Landin.Testing.Context)
   is
      Windows : constant Snapshot :=
        Create (1, "crlf.ldn", "one" & CR & LF & "two");
      Classic : constant Snapshot :=
        Create (2, "cr.ldn", "one" & CR & "two");
   begin
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Windows)), 2, "CR LF ends one line");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Windows, 1), "one",
         "CR is not part of the line text");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Windows, 2), "two", "second line after CR LF");
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Classic)), 2, "a lone CR ends a line");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Classic, 1), "one",
         "a lone CR is not part of the line it ends");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Classic, 2), "two", "second line after a lone CR");
   end Carriage_Returns_Terminate;

   procedure Positions_Follow_Bytes (Item : in out Landin.Testing.Context);

   procedure Positions_Follow_Bytes (Item : in out Landin.Testing.Context) is
      Snap : constant Snapshot :=
        Create (1, "p.ldn", "ab" & LF & "cde" & LF);
   begin
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Snap, 0).Line), 1, "offset 0 line");
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Snap, 0).Column), 1, "offset 0 column");
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Snap, 1).Column), 2, "offset 1 column");
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Snap, 3).Line), 2, "offset 3 line");
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Snap, 3).Column), 1, "offset 3 column");
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Snap, 5).Column), 3, "offset 5 column");
   end Positions_Follow_Bytes;

   procedure Slices_Return_Requested_Bytes
     (Item : in out Landin.Testing.Context);

   procedure Slices_Return_Requested_Bytes
     (Item : in out Landin.Testing.Context)
   is
      Snap : constant Snapshot := Create (1, "s.ldn", "abcdef");
   begin
      Landin.Testing.Check_Equal
        (Item, Slice (Snap, (First => 0, Last => 3)), "abc", "leading slice");
      Landin.Testing.Check_Equal
        (Item, Slice (Snap, (First => 3, Last => 6)), "def", "trailing slice");
      Landin.Testing.Check_Equal
        (Item, Slice (Snap, (First => 2, Last => 2)), "", "empty slice");
      Landin.Testing.Check
        (Item, Is_Valid (Snap, (First => 0, Last => 6)),
         "the full span is valid");
      Landin.Testing.Check
        (Item, not Is_Valid (Snap, (First => 0, Last => 7)),
         "a span past the end is not valid");
   end Slices_Return_Requested_Bytes;

   procedure Sets_Assign_Stable_Identities
     (Item : in out Landin.Testing.Context);

   procedure Sets_Assign_Stable_Identities
     (Item : in out Landin.Testing.Context)
   is
      Set    : Landin.Source.Sets.Source_Set;
      First  : constant Source_Id := Set.Add ("a.ldn", "aaa");
      Second : constant Source_Id := Set.Add ("a.ldn", "bbb");
   begin
      Landin.Testing.Check (Item, First /= Second,
                            "two files with one name are two sources");
      Landin.Testing.Check_Equal (Item, Set.Count, 2, "both were added");
      Landin.Testing.Check_Equal
        (Item, Text (Set.Get (First)), "aaa", "first content");
      Landin.Testing.Check_Equal
        (Item, Text (Set.Get (Second)), "bbb", "second content");
      Landin.Testing.Check
        (Item, not Set.Contains (No_Source), "no source is not a member");
      Landin.Testing.Check
        (Item, Set.Nth (1) = First, "insertion order is preserved");
   end Sets_Assign_Stable_Identities;

   procedure Invalid_Offsets_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Invalid_Offsets_Are_Refused
     (Item : in out Landin.Testing.Context)
   is
      Snap  : constant Snapshot := Create (1, "v.ldn", "abc");
      Where : Position;
   begin
      Landin.Testing.Check
        (Item, Is_Valid (Snap, Byte_Offset (3)),
         "one past the end is a valid offset");
      Landin.Testing.Check
        (Item, not Is_Valid (Snap, Byte_Offset (4)),
         "past one past the end is not valid");

      Where := Position_Of (Snap, Byte_Offset (4));
      Landin.Testing.Fail (Item, "an invalid offset should be refused");
      pragma Assert (Where.Line >= 1);
   exception
      when others =>
         Landin.Testing.Check
           (Item, True, "resolving an invalid offset is refused");
   end Invalid_Offsets_Are_Refused;

   procedure Provenance_Is_A_Side_Table
     (Item : in out Landin.Testing.Context);

   procedure Provenance_Is_A_Side_Table
     (Item : in out Landin.Testing.Context)
   is
      use type Landin.Provenance.Declaration_Id;

      Sites : Landin.Provenance.Table;
      First : constant Landin.Provenance.Declaration_Id :=
        Sites.Record_Site ((Source => 1, Where => (First => 0, Last => 3)));
      Later : constant Landin.Provenance.Declaration_Id :=
        Sites.Record_Site ((Source => 2, Where => (First => 4, Last => 9)));
   begin
      Landin.Testing.Check
        (Item, First /= Later, "two sites get two identities");
      Landin.Testing.Check_Equal (Item, Sites.Count, 2, "both were recorded");
      Landin.Testing.Check
        (Item, not Sites.Contains (Landin.Provenance.No_Declaration),
         "the absent identity is never present");
      Landin.Testing.Check
        (Item, Sites.Site (Later).Source = 2, "the site round trips");
      Landin.Testing.Check
        (Item,
         not Landin.Provenance.Is_Known (Landin.Provenance.No_Origin),
         "an unknown origin says so");
   end Provenance_Is_A_Side_Table;

   --  Text ending in a terminator of each kind, and text that is nothing
   --  but terminators.  The line map is the one piece of the chassis every
   --  diagnostic position goes through.
   procedure Terminator_Only_Text (Item : in out Landin.Testing.Context);

   procedure Terminator_Only_Text (Item : in out Landin.Testing.Context) is
      Only_CR   : constant Snapshot := Create (1, "cr.ldn", "" & CR);
      Only_LF   : constant Snapshot := Create (2, "lf.ldn", "" & LF);
      Only_CRLF : constant Snapshot := Create (3, "crlf.ldn", CR & LF);
      Two_CR    : constant Snapshot := Create (4, "twocr.ldn", CR & CR);
   begin
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Only_CR)), 2, "one CR is two lines");
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Only_LF)), 2, "one LF is two lines");
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Only_CRLF)), 2,
         "CR LF together is one terminator");
      Landin.Testing.Check_Equal
        (Item, Natural (Line_Count (Two_CR)), 3, "two CRs are three lines");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Only_CR, 1), "", "the first line is empty");
      Landin.Testing.Check_Equal
        (Item, Line_Text (Only_CR, 2), "", "and so is the last");
      Landin.Testing.Check_Equal
        (Item, Natural (Position_Of (Only_CRLF, Length (Only_CRLF)).Line), 2,
         "one past the end of CR LF is line two");
   end Terminator_Only_Text;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "source", "empty text has one line",
         Empty_Text_Has_One_Line'Access);
      Landin.Testing.Register
        (Into, "source", "line feed maps lines",
         Line_Feed_Maps_Lines'Access);
      Landin.Testing.Register
        (Into, "source", "trailing terminator adds a line",
         Trailing_Terminator_Adds_A_Line'Access);
      Landin.Testing.Register
        (Into, "source", "carriage returns terminate",
         Carriage_Returns_Terminate'Access);
      Landin.Testing.Register
        (Into, "source", "positions follow bytes",
         Positions_Follow_Bytes'Access);
      Landin.Testing.Register
        (Into, "source", "slices return requested bytes",
         Slices_Return_Requested_Bytes'Access);
      Landin.Testing.Register
        (Into, "source", "sets assign stable identities",
         Sets_Assign_Stable_Identities'Access);
      Landin.Testing.Register
        (Into, "source", "invalid offsets are refused",
         Invalid_Offsets_Are_Refused'Access);
      Landin.Testing.Register
        (Into, "source", "provenance is a side table",
         Provenance_Is_A_Side_Table'Access);
      Landin.Testing.Register
        (Into, "source", "terminator only text",
         Terminator_Only_Text'Access);
   end Register;

end Landin.Tests.Source_Suite;
