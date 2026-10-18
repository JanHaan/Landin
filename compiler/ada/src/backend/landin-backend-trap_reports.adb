with Landin.Backend.Dwarf;

package body Landin.Backend.Trap_Reports is

   function Index_Of (Into : in out Table; Text : String) return Positive is
      Found : constant Index_Maps.Cursor := Into.Seen.Find (Text);
   begin
      if Index_Maps.Has_Element (Found) then
         return Index_Maps.Element (Found);
      end if;
      Into.Lines.Append (Text);
      Into.Seen.Insert (Text, Into.Lines.Last_Index);
      return Into.Lines.Last_Index;
   end Index_Of;

   function Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Lines.Length));

   function Text (Of_Table : Table; Index : Positive) return String
     is (Of_Table.Lines (Index));

   function Quoted (Bytes : String) return String
     is (Landin.Backend.Dwarf.Quoted (Bytes));

end Landin.Backend.Trap_Reports;
