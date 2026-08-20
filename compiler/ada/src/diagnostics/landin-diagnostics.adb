package body Landin.Diagnostics is

   use type Landin.Source.Source_Id;
   use type Landin.Source.Byte_Offset;

   function Make_Label
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Role    : Label_Role := Secondary) return Label
   is
     (Source => Source,
      Where  => Where,
      Text   => ASU.To_Unbounded_String (Message),
      Role   => Role);

   function Source_Of (Item : Label) return Landin.Source.Source_Id
     is (Item.Source);

   function Span_Of (Item : Label) return Landin.Source.Span
     is (Item.Where);

   function Message (Item : Label) return String
     is (ASU.To_String (Item.Text));

   function Role (Item : Label) return Label_Role is (Item.Role);

   function Make
     (Code     : Code_String;
      Level    : Severity;
      Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Message  : String) return Diagnostic
   is
      Result : Diagnostic;
   begin
      Result.Code    := Code;
      Result.Level   := Level;
      Result.Primary :=
        Make_Label (Source, Where, Message, Role => Primary);
      return Result;
   end Make;

   function Code (Item : Diagnostic) return Code_String is (Item.Code);

   function Level (Item : Diagnostic) return Severity is (Item.Level);

   function Primary (Item : Diagnostic) return Label is (Item.Primary);

   procedure Add_Label (Item : in out Diagnostic; Extra : Label) is
   begin
      Item.Labels.Append (Extra);
   end Add_Label;

   function Label_Count (Item : Diagnostic) return Natural
     is (Natural (Item.Labels.Length));

   function Nth_Label (Item : Diagnostic; Index : Positive) return Label
     is (Item.Labels.Element (Index));

   procedure Add_Note (Item : in out Diagnostic; Text : String) is
   begin
      Item.Notes.Append (Text);
   end Add_Note;

   function Note_Count (Item : Diagnostic) return Natural
     is (Natural (Item.Notes.Length));

   function Nth_Note (Item : Diagnostic; Index : Positive) return String
     is (Item.Notes.Element (Index));

   procedure Append (List : in out Diagnostic_List; Item : Diagnostic) is
   begin
      List.Items.Append (Item);
   end Append;

   function Count (List : Diagnostic_List) return Natural
     is (Natural (List.Items.Length));

   function Get (List : Diagnostic_List; Index : Positive) return Diagnostic
     is (List.Items.Element (Index));

   function Has_Errors (List : Diagnostic_List) return Boolean
     is (Count_Of (List, Error) > 0);

   function Count_Of
     (List : Diagnostic_List; Of_Level : Severity) return Natural
   is
      Total : Natural := 0;
   begin
      for Item of List.Items loop
         if Item.Level = Of_Level then
            Total := Total + 1;
         end if;
      end loop;
      return Total;
   end Count_Of;

   ---------------------------------------------------------------------
   --  Sorted
   --
   --  The comparison is total on purpose.  An ordering that ties on the
   --  span leaves the report at the mercy of the order the stages ran in,
   --  and that is how a negative fixture becomes flaky.
   ---------------------------------------------------------------------

   function Precedes (Left, Right : Diagnostic) return Boolean;

   function Precedes (Left, Right : Diagnostic) return Boolean is
      Left_Source  : constant Landin.Source.Source_Id := Left.Primary.Source;
      Right_Source : constant Landin.Source.Source_Id := Right.Primary.Source;
   begin
      if Left_Source /= Right_Source then
         return Left_Source < Right_Source;
      end if;

      if Left.Primary.Where.First /= Right.Primary.Where.First then
         return Left.Primary.Where.First < Right.Primary.Where.First;
      end if;

      if Left.Primary.Where.Last /= Right.Primary.Where.Last then
         return Left.Primary.Where.Last < Right.Primary.Where.Last;
      end if;

      if Left.Level /= Right.Level then
         return Left.Level > Right.Level;
      end if;

      if Left.Code /= Right.Code then
         return Left.Code < Right.Code;
      end if;

      return ASU.To_String (Left.Primary.Text)
             < ASU.To_String (Right.Primary.Text);
   end Precedes;

   ---------------------------------------------------------------------
   --  Sorted
   --
   --  Decorated with arrival position, so two diagnostics that tie on
   --  every compared key keep the order they arrived in.  Without it the
   --  underlying sort is free to permute them, and "the same report every
   --  run" would be true only until two reports tied.
   ---------------------------------------------------------------------

   type Placed is record
      Arrival : Positive;
      Item    : Diagnostic;
   end record;

   package Placed_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Placed);

   function Placed_Precedes (Left, Right : Placed) return Boolean;

   function Placed_Precedes (Left, Right : Placed) return Boolean is
   begin
      if Precedes (Left.Item, Right.Item) then
         return True;
      end if;

      if Precedes (Right.Item, Left.Item) then
         return False;
      end if;

      return Left.Arrival < Right.Arrival;
   end Placed_Precedes;

   package Sorting is new Placed_Vectors.Generic_Sorting
     ("<" => Placed_Precedes);

   function Sorted (List : Diagnostic_List) return Diagnostic_List is
      Decorated : Placed_Vectors.Vector;
      Result    : Diagnostic_List;
   begin
      for Index in 1 .. Count (List) loop
         Decorated.Append (Placed'(Arrival => Index,
                                   Item    => Get (List, Index)));
      end loop;

      Sorting.Sort (Decorated);

      for Item of Decorated loop
         Result.Items.Append (Item.Item);
      end loop;

      return Result;
   end Sorted;

end Landin.Diagnostics;
