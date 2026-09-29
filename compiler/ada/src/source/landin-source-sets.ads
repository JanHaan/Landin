--  A compilation's set of source snapshots.
--
--  Snapshots are added once, keep the identity they were given, and are
--  iterated in insertion order.  Nothing here reads a file: acquiring bytes
--  is a host concern and belongs to Landin.Platform, so a test can build a
--  whole compilation out of literals.
--
--  The set owns its snapshots and frees them with itself.  Get hands one
--  out by reference, from an aliased set, so a reader cannot keep it past
--  the set that holds it.

private with Ada.Containers.Vectors;
private with Ada.Finalization;

package Landin.Source.Sets is

   type Source_Set is tagged limited private;

   function Count (Set : Source_Set) return Natural;

   --  Adds Text under Name and returns its stable identity.  Two files may
   --  carry the same name (a fixture and its copy) and still be distinct
   --  sources, so names are not keys.
   function Add
     (Set : in out Source_Set; Name : String; Text : String) return Source_Id
     with Post => Count (Set) = Count (Set)'Old + 1
                  and then Add'Result /= No_Source;

   function Contains (Set : Source_Set; Id : Source_Id) return Boolean;

   function Get (Set : aliased Source_Set; Id : Source_Id)
     return Snapshot_Reference
     with Pre => Contains (Set, Id);

   --  Identity of the N'th snapshot in insertion order, so rendering and
   --  reporting can be deterministic without sorting by name.
   function Nth (Set : Source_Set; Index : Positive) return Source_Id
     with Pre => Index <= Count (Set);

private

   type Snapshot_Access is access Snapshot;

   package Snapshot_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Snapshot_Access);

   type Held is new Ada.Finalization.Limited_Controlled with record
      Items : Snapshot_Vectors.Vector;
   end record;

   overriding procedure Finalize (Owned : in out Held);

   type Source_Set is tagged limited record
      Owned : Held;
   end record;

end Landin.Source.Sets;
