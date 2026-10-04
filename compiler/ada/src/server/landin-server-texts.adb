with Ada.Unchecked_Deallocation;

package body Landin.Server.Texts is

   procedure Free is new Ada.Unchecked_Deallocation
     (String, String_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Block, Block_Access);

   use type Piece_Lists.Cursor;

   --  Insert a slice before Before, and count it as a user of its string.
   procedure Insert
     (Into : in out Buffer; Before : Piece_Lists.Cursor; Part : Piece);

   procedure Insert
     (Into : in out Buffer; Before : Piece_Lists.Cursor; Part : Piece) is
   begin
      Part.Data.Users := Part.Data.Users + 1;
      Into.Pieces.Insert (Before, Part);
   end Insert;

   --  Delete a slice, and free its string if no other slice names it.
   procedure Delete (Into : in out Buffer; Position : Piece_Lists.Cursor);

   procedure Delete (Into : in out Buffer; Position : Piece_Lists.Cursor) is
      Data : Block_Access := Piece_Lists.Element (Position).Data;
      Gone : Piece_Lists.Cursor := Position;
   begin
      Into.Pieces.Delete (Gone);
      Data.Users := Data.Users - 1;
      if Data.Users = 0 then
         Into.Strings := Into.Strings - 1;
         Into.Bytes := Into.Bytes - Data.Data'Length;
         Free (Data.Data);
         Free (Data);
      end if;
   end Delete;

   --  A new string holding Text, as one slice before Before.
   procedure Add
     (Into : in out Buffer; Before : Piece_Lists.Cursor; Text : String);

   procedure Add
     (Into : in out Buffer; Before : Piece_Lists.Cursor; Text : String)
   is
      Data : Block_Access;
   begin
      if Text'Length = 0 then
         return;
      end if;
      Data := new Block'(Data => new String'(Text), Users => 0);
      Into.Strings := Into.Strings + 1;
      Into.Bytes := Into.Bytes + Text'Length;
      Insert (Into, Before,
              (Data => Data, First => Data.Data'First,
               Length => Text'Length));
   end Add;

   procedure Clear (Into : in out Buffer);

   procedure Clear (Into : in out Buffer) is
   begin
      while not Into.Pieces.Is_Empty loop
         Delete (Into, Into.Pieces.First);
      end loop;
      Into.Length := 0;
   end Clear;

   overriding procedure Finalize (Into : in out Buffer) is
   begin
      Clear (Into);
   end Finalize;

   procedure Replace (Into : in out Buffer; Text : String) is
   begin
      Clear (Into);
      Add (Into, Piece_Lists.No_Element, Text);
      Into.Length := Text'Length;
      Into.Dirty := True;
   end Replace;

   procedure Open (Into : in out Buffer; Text : String) is
   begin
      Replace (Into, Text);
      Into.Dirty := False;
   end Open;

   type Cursor is record
      Part   : Piece_Lists.Cursor := Piece_Lists.No_Element;
      Within : Natural := 0;
      Offset : Natural := 0;
   end record;

   function Start (From : Buffer) return Cursor
     is (Part => From.Pieces.First, others => 0);

   procedure Advance (Spot : in out Cursor; Count : Natural);

   procedure Advance (Spot : in out Cursor; Count : Natural) is
      Left : Natural := Count;
   begin
      while Left > 0 and then Spot.Part /= Piece_Lists.No_Element loop
         declare
            Available : constant Natural :=
              Piece_Lists.Element (Spot.Part).Length - Spot.Within;
            Taken : constant Natural := Natural'Min (Left, Available);
         begin
            Spot.Within := Spot.Within + Taken;
            Spot.Offset := Spot.Offset + Taken;
            Left := Left - Taken;
            if Spot.Within = Piece_Lists.Element (Spot.Part).Length then
               Spot.Part := Piece_Lists.Next (Spot.Part);
               Spot.Within := 0;
            end if;
         end;
      end loop;
   end Advance;

   --  -1 at the end, otherwise the byte Ahead bytes from Spot.
   function Peek (Spot : Cursor; Ahead : Natural := 0) return Integer;

   function Peek (Spot : Cursor; Ahead : Natural := 0) return Integer is
      Next : Cursor := Spot;
   begin
      Advance (Next, Ahead);
      if Next.Part = Piece_Lists.No_Element then
         return -1;
      end if;
      declare
         Part : constant Piece := Piece_Lists.Element (Next.Part);
      begin
         return Character'Pos (Part.Data.Data (Part.First + Next.Within));
      end;
   end Peek;

   --  The byte offset Positions.Offset_Of would give, read from the
   --  slices up to that byte and no further.
   function Locate
     (From : Buffer; Where : Positions.Position; Unit : Positions.Encoding)
      return Natural;

   function Locate
     (From : Buffer; Where : Positions.Position; Unit : Positions.Encoding)
      return Natural
   is
      Spot   : Cursor := Start (From);
      Line   : Natural := 0;
      Column : Natural := 0;
   begin
      while Line < Where.Line loop
         case Peek (Spot) is
            when -1 =>
               return Spot.Offset;
            when 10 =>
               Advance (Spot, 1);
               Line := Line + 1;
            when 13 =>
               Advance (Spot, 1);
               if Peek (Spot) = 10 then
                  Advance (Spot, 1);
               end if;
               Line := Line + 1;
            when others =>
               Advance (Spot, 1);
         end case;
      end loop;
      while Peek (Spot) not in -1 | 10 | 13 loop
         declare
            Size : constant Positive := Positions.Width
              (Peek (Spot), Peek (Spot, 1), Peek (Spot, 2), Peek (Spot, 3));
            Next : constant Natural := Column + Positions.Units (Size, Unit);
         begin
            exit when Next > Where.Character;
            Column := Next;
            Advance (Spot, Size);
         end;
      end loop;
      return Spot.Offset;
   end Locate;

   --  The slice that starts at Offset, splitting one that spans it, or
   --  No_Element at the end.
   function Split_At (Into : in out Buffer; Offset : Natural)
     return Piece_Lists.Cursor;

   function Split_At (Into : in out Buffer; Offset : Natural)
     return Piece_Lists.Cursor
   is
      Position : Piece_Lists.Cursor := Into.Pieces.First;
      Passed   : Natural := 0;
   begin
      while Position /= Piece_Lists.No_Element loop
         declare
            Part : constant Piece := Piece_Lists.Element (Position);
         begin
            if Offset = Passed then
               return Position;
            elsif Offset < Passed + Part.Length then
               declare
                  Left  : Piece := Part;
                  Right : Piece := Part;
               begin
                  Left.Length := Offset - Passed;
                  Right.First := Part.First + Left.Length;
                  Right.Length := Part.Length - Left.Length;
                  Into.Pieces.Replace_Element (Position, Left);
                  Insert (Into, Piece_Lists.Next (Position), Right);
                  return Piece_Lists.Next (Position);
               end;
            end if;
            Passed := Passed + Part.Length;
            Position := Piece_Lists.Next (Position);
         end;
      end loop;
      return Piece_Lists.No_Element;
   end Split_At;

   procedure Edit
     (Into : in out Buffer;
      First, Last : Positions.Position;
      Unit : Positions.Encoding; Text : String)
   is
      Begin_At : constant Natural := Locate (Into, First, Unit);
      End_At   : constant Natural := Locate (Into, Last, Unit);
      Beginning, Ending : Piece_Lists.Cursor;
   begin
      Beginning := Split_At (Into, Begin_At);
      Ending := Split_At (Into, End_At);
      while Beginning /= Ending loop
         declare
            Removing : constant Piece_Lists.Cursor := Beginning;
         begin
            Beginning := Piece_Lists.Next (Beginning);
            Delete (Into, Removing);
         end;
      end loop;
      Add (Into, Ending, Text);
      Into.Length := Into.Length - (End_At - Begin_At) + Text'Length;
      Into.Dirty := True;
      --  A deleted byte stays in its string while any slice of that string
      --  remains.  Once deleted bytes outweigh the text, copy the text out
      --  into one string: those deletions walked over every one of them,
      --  so the copy costs no more than they already did, and the strings
      --  never hold more than twice the text.
      if Into.Bytes - Into.Length > Into.Length then
         Replace (Into, Content (Into));
      end if;
   end Edit;

   function Content (From : Buffer) return String is
      Result : String (1 .. From.Length);
      Next   : Positive := 1;
   begin
      for Part of From.Pieces loop
         Result (Next .. Next + Part.Length - 1) :=
           Part.Data.Data (Part.First .. Part.First + Part.Length - 1);
         Next := Next + Part.Length;
      end loop;
      return Result;
   end Content;

   function Length (From : Buffer) return Natural is (From.Length);

   function Is_Dirty (From : Buffer) return Boolean is (From.Dirty);

   function Stored_Strings (From : Buffer) return Natural is (From.Strings);

   function Stored_Bytes (From : Buffer) return Natural is (From.Bytes);

end Landin.Server.Texts;
