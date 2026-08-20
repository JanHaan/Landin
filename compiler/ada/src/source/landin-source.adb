with Ada.Containers.Vectors;

package body Landin.Source is

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Byte_Offset);

   ---------------------------------------------------------------------
   --  Create
   --
   --  A line starts at offset 0 and after every terminator.  LF, CR LF
   --  and a lone CR all terminate a line, so a file written on any of the
   --  three conventions maps to the same lines.  Text that ends with a
   --  terminator therefore has a final empty line: that line is where a
   --  one-past-the-end offset resolves, which is exactly the position a
   --  diagnostic about a missing closing token needs.
   --
   --  This is presentation, not lexis.  Which byte sequences a Landin
   --  source may use to end a line is R1.20's to state normatively in
   --  tour.txt; until it does, the line map is deliberately generous so
   --  that a diagnostic never points at the wrong line.
   ---------------------------------------------------------------------

   function Create
     (Id : Source_Id; Name : String; Text : String) return Snapshot
   is
      Starts : Offset_Vectors.Vector;
      Index  : Integer := Text'First;

      function Offset_At (Position : Integer) return Byte_Offset
        is (Byte_Offset (Position - Text'First));

   begin
      Starts.Append (0);

      while Index <= Text'Last loop
         if Text (Index) = LF then
            Starts.Append (Offset_At (Index + 1));
         elsif Text (Index) = CR then
            if Index < Text'Last and then Text (Index + 1) = LF then
               Index := Index + 1;
            end if;
            Starts.Append (Offset_At (Index + 1));
         end if;
         Index := Index + 1;
      end loop;

      declare
         Count : constant Line_Number := Line_Number (Starts.Length);
         Map   : constant Mutable_Offsets := new Offset_Array (1 .. Count);
      begin
         for Line in 1 .. Count loop
            Map (Line) := Starts.Element (Positive (Line));
         end loop;

         return
           (Id          => Id,
            Name        => ASU.To_Unbounded_String (Name),
            Bytes       => new String'(Text),
            Line_Starts => Offsets_Access (Map));
      end;
   end Create;

   function Id (Item : Snapshot) return Source_Id is (Item.Id);

   function Name (Item : Snapshot) return String
     is (ASU.To_String (Item.Name));

   function Text (Item : Snapshot) return String is (Item.Bytes.all);

   function Length (Item : Snapshot) return Byte_Offset
     is (Byte_Offset (Item.Bytes.all'Length));

   function Full_Span (Item : Snapshot) return Span
     is (First => 0, Last => Length (Item));

   function Slice (Item : Snapshot; Where : Span) return String is
      First : constant Integer := Integer (Where.First) + 1;
      Last  : constant Integer := Integer (Where.Last);
   begin
      return Item.Bytes.all (First .. Last);
   end Slice;

   function Line_Count (Item : Snapshot) return Line_Number
     is (Item.Line_Starts.all'Last);

   ---------------------------------------------------------------------
   --  Position_Of
   --
   --  Binary search over the line map.  Linear scanning was the first
   --  version and it made rendering a large file quadratic.
   ---------------------------------------------------------------------

   function Position_Of (Item : Snapshot; Offset : Byte_Offset) return Position
   is
      Low  : Line_Number := 1;
      High : Line_Number := Line_Count (Item);
      Mid  : Line_Number;
   begin
      if Offset > Length (Item) then
         raise Compiler_Defect
           with "source offset past the end of the snapshot";
      end if;

      while Low < High loop
         Mid := Low + (High - Low + 1) / 2;
         if Item.Line_Starts (Mid) <= Offset then
            Low := Mid;
         else
            High := Mid - 1;
         end if;
      end loop;

      return
        (Line   => Low,
         Column => Column_Number (Offset - Item.Line_Starts (Low) + 1));
   end Position_Of;

   function Line_Span (Item : Snapshot; Line : Line_Number) return Span is
      First : constant Byte_Offset := Item.Line_Starts (Line);
   begin
      if Line = Line_Count (Item) then
         return (First => First, Last => Length (Item));
      else
         return (First => First, Last => Item.Line_Starts (Line + 1));
      end if;
   end Line_Span;

   function Line_Text (Item : Snapshot; Line : Line_Number) return String is
      Where : Span := Line_Span (Item, Line);
   begin
      if Where.Last > Where.First
        and then Item.Bytes.all (Integer (Where.Last)) = LF
      then
         Where.Last := Where.Last - 1;
      end if;

      if Where.Last > Where.First
        and then Item.Bytes.all (Integer (Where.Last)) = CR
      then
         Where.Last := Where.Last - 1;
      end if;

      return Slice (Item, Where);
   end Line_Text;

end Landin.Source;
