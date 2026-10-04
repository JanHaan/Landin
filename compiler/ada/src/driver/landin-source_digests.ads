with Landin.Source;

--  Per-emission digests of immutable source snapshots. Source identities are
--  assigned consecutively by the compilation's source set.
package Landin.Source_Digests is
   type Cache (Count : Landin.Source.Source_Id) is private;

   function Digest
     (From : in out Cache; Snapshot : Landin.Source.Snapshot) return String
     with Pre => Landin.Source.Id (Snapshot) in 1 .. From.Count;

private
   type Digest_Array is array (Landin.Source.Source_Id range <>) of
     String (1 .. 64);

   type Cache (Count : Landin.Source.Source_Id) is record
      Values : Digest_Array (1 .. Count) := [others => [others => ' ']];
   end record;
end Landin.Source_Digests;
