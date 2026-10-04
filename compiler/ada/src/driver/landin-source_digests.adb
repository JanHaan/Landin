with GNAT.SHA256;

package body Landin.Source_Digests is
   function Digest
     (From : in out Cache; Snapshot : Landin.Source.Snapshot) return String
   is
      Id : constant Landin.Source.Source_Id := Landin.Source.Id (Snapshot);
   begin
      if From.Values (Id) (1) = ' ' then
         From.Values (Id) := GNAT.SHA256.Digest
           (Landin.Source.Text (Snapshot));
      end if;
      return From.Values (Id);
   end Digest;
end Landin.Source_Digests;
