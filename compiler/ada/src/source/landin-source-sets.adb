package body Landin.Source.Sets is

   function Count (Set : Source_Set) return Natural
     is (Natural (Set.Items.Length));

   function Add
     (Set : in out Source_Set; Name : String; Text : String) return Source_Id
   is
      Id : constant Source_Id := Source_Id (Count (Set) + 1);
   begin
      Set.Items.Append (Create (Id, Name, Text));
      return Id;
   end Add;

   function Contains (Set : Source_Set; Id : Source_Id) return Boolean
     is (Id /= No_Source and then Natural (Id) <= Count (Set));

   function Get (Set : Source_Set; Id : Source_Id) return Snapshot
     is (Set.Items.Element (Positive (Id)));

   function Nth (Set : Source_Set; Index : Positive) return Source_Id
     is (Set.Items.Element (Index).Id);

end Landin.Source.Sets;
