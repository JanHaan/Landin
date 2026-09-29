with Ada.Unchecked_Deallocation;

package body Landin.Source.Sets is

   procedure Free is new Ada.Unchecked_Deallocation
     (Snapshot, Snapshot_Access);

   overriding procedure Finalize (Owned : in out Held) is
   begin
      for Item of Owned.Items loop
         Free (Item);
      end loop;
      Owned.Items.Clear;
   end Finalize;

   function Count (Set : Source_Set) return Natural
     is (Natural (Set.Owned.Items.Length));

   function Add
     (Set : in out Source_Set; Name : String; Text : String) return Source_Id
   is
      Id : constant Source_Id := Source_Id (Count (Set) + 1);
   begin
      Set.Owned.Items.Append (new Snapshot'(Create (Id, Name, Text)));
      return Id;
   end Add;

   function Contains (Set : Source_Set; Id : Source_Id) return Boolean
     is (Id /= No_Source and then Natural (Id) <= Count (Set));

   function Get (Set : aliased Source_Set; Id : Source_Id)
     return Snapshot_Reference
     is (Element => Set.Owned.Items.Element (Positive (Id)));

   function Nth (Set : Source_Set; Index : Positive) return Source_Id
     is (Set.Owned.Items.Element (Index).Id);

end Landin.Source.Sets;
