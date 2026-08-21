package body Landin.Source.Names is

   function Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Spellings.Length));

   function Is_Interned (Of_Table : Table; Id : Name_Id) return Boolean
     is (Id /= No_Name and then Natural (Id) <= Count (Of_Table));

   function Intern (Into : in out Table; Text : String) return Name_Id is
      found : constant Name_Maps.Cursor := Into.Index.Find (Text);
   begin
      if Name_Maps.Has_Element (found) then
         return Name_Maps.Element (found);
      end if;

      Into.Spellings.Append (Text);

      declare
         Fresh : constant Name_Id := Name_Id (Into.Spellings.Length);
      begin
         Into.Index.Insert (Text, Fresh);
         return Fresh;
      end;
   end Intern;

   function Intern
     (Into : in out Table; From : Snapshot; Where : Span) return Name_Id
     is (Intern (Into, Slice (From, Where)));

   function Spelling (Of_Table : Table; Id : Name_Id) return String
     is (Of_Table.Spellings.Element (Positive (Id)));

   function Hash (Id : Name_Id) return Ada.Containers.Hash_Type
     is (Ada.Containers.Hash_Type (Id));

end Landin.Source.Names;
