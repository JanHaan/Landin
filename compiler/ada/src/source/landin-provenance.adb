package body Landin.Provenance is

   use type Landin.Source.Source_Id;

   function Is_Known (Item : Origin) return Boolean
     is (Item.Source /= Landin.Source.No_Source);

   function Record_Site
     (Into : in out Table; Site : Origin) return Declaration_Id
   is
   begin
      Into.Items.Append (Site);
      return Declaration_Id (Into.Items.Length);
   end Record_Site;

   function Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Items.Length));

   function Contains (Of_Table : Table; Id : Declaration_Id) return Boolean
     is (Id /= No_Declaration and then Natural (Id) <= Count (Of_Table));

   function Site (Of_Table : Table; Id : Declaration_Id) return Origin
     is (Of_Table.Items.Element (Positive (Id)));

end Landin.Provenance;
