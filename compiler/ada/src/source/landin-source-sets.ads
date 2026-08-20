--  A compilation's set of source snapshots.
--
--  Snapshots are added once, keep the identity they were given, and are
--  iterated in insertion order.  Nothing here reads a file: acquiring bytes
--  is a host concern and belongs to Landin.Platform, so a test can build a
--  whole compilation out of literals.

with Ada.Containers.Vectors;

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

   function Get (Set : Source_Set; Id : Source_Id) return Snapshot
     with Pre => Contains (Set, Id);

   --  Identity of the N'th snapshot in insertion order, so rendering and
   --  reporting can be deterministic without sorting by name.
   function Nth (Set : Source_Set; Index : Positive) return Source_Id
     with Pre => Index <= Count (Set);

private

   package Snapshot_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Snapshot);

   type Source_Set is tagged limited record
      Items : Snapshot_Vectors.Vector;
   end record;

end Landin.Source.Sets;
