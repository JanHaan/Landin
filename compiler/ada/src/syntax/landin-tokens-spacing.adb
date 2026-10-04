with Ada.Unchecked_Deallocation;

package body Landin.Tokens.Spacing is

   use type Landin.Source.Byte_Offset;

   procedure Free is
     new Ada.Unchecked_Deallocation (Space_Array, Space_Access);

   overriding procedure Finalize (Owned : in out Held) is
   begin
      for Row of Owned.Rows loop
         Free (Row);
      end loop;
      Owned.Rows.Clear;
   end Finalize;

   function Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Owned.Rows.Length));

   procedure Add (Into : in out Table; From : Token_Stream) is
      Row : constant Space_Access :=
        new Space_Array (1 .. Natural (From.Spaces.Length));
   begin
      for Index in Row'Range loop
         Row (Index) := From.Spaces.Element (Index);
      end loop;
      Into.Owned.Rows.Append (Row);
   end Add;

   procedure Transfer_Next (From : in out Table; Into : in out Table) is
      Index : constant Positive := Count (Into) + 1;
      Row   : constant Space_Access := From.Owned.Rows.Element (Index);
   begin
      if Row = null then
         raise Landin.Compiler_Defect with "syntax space already transferred";
      end if;
      Into.Owned.Rows.Append (Row);
      From.Owned.Rows.Replace_Element (Index, null);
   end Transfer_Next;

   procedure Copy_Add
     (Into : in out Table;
      From : Table;
      Id   : Landin.Source.Source_Id)
   is
      Row : constant Space_Access := From.Owned.Rows.Element (Positive (Id));
   begin
      Into.Owned.Rows.Append (new Space_Array'(Row.all));
   end Copy_Add;

   function Row_Of
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Space_Access
     is (Of_Table.Owned.Rows.Element (Positive (Id)));

   function Space_Count
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     is (Row_Of (Of_Table, Id)'Length);

   function Nth_Space
     (Of_Table : Table;
      Id       : Landin.Source.Source_Id;
      Index    : Positive) return Space
     is (Row_Of (Of_Table, Id) (Index));

   function Within
     (Of_Table : Table;
      Id       : Landin.Source.Source_Id;
      Where    : Landin.Source.Span) return Space_Range
   is
      Row : constant Space_Access := Row_Of (Of_Table, Id);

      --  How many pieces satisfy Before.  The pieces are in byte order and
      --  never overlap, so both their starts and their ends ascend, and
      --  each question below is true of a prefix: a binary search.
      function Prefix
        (Before : not null access function (Item : Space) return Boolean)
         return Natural;

      function Prefix
        (Before : not null access function (Item : Space) return Boolean)
         return Natural
      is
         Low  : Natural := 0;
         High : Natural := Row'Length;
      begin
         while Low < High loop
            declare
               Middle : constant Positive := Low + (High - Low + 1) / 2;
            begin
               if Before (Row (Middle)) then
                  Low := Middle;
               else
                  High := Middle - 1;
               end if;
            end;
         end loop;
         return Low;
      end Prefix;

      function Starts_Early (Item : Space) return Boolean
        is (Item.Where.First < Where.First);

      function Ends_In_Time (Item : Space) return Boolean
        is (Item.Where.Last <= Where.Last);
   begin
      return (First => Prefix (Starts_Early'Access) + 1,
              Last  => Prefix (Ends_In_Time'Access));
   end Within;

end Landin.Tokens.Spacing;
