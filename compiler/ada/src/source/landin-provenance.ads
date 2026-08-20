--  Where something came from.
--
--  A span says where bytes are; an origin says which source those bytes are
--  in; a declaration identity says which declared thing a later stage is
--  talking about.  All three are carriers, not meanings: nothing here knows
--  what a declaration is, only that one can be pointed at.
--
--  The declaration table is a side table on purpose.  Construct [1670] wants
--  a panic site to be a small compiler-assigned number with its file and
--  line held elsewhere, so a constrained build can drop the table without
--  changing the code that refers to it.

with Ada.Containers.Vectors;

with Landin.Source;

package Landin.Provenance is

   type Origin is record
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where  : Landin.Source.Span      := Landin.Source.Empty_Span;
   end record;

   No_Origin : constant Origin :=
     (Source => Landin.Source.No_Source, Where => Landin.Source.Empty_Span);

   function Is_Known (Item : Origin) return Boolean;

   type Declaration_Id is range 0 .. Integer'Last;
   No_Declaration : constant Declaration_Id := 0;

   type Table is tagged limited private;

   function Record_Site
     (Into : in out Table; Site : Origin) return Declaration_Id
     with Pre  => Is_Known (Site),
          Post => Record_Site'Result /= No_Declaration;

   function Count (Of_Table : Table) return Natural;

   function Contains (Of_Table : Table; Id : Declaration_Id) return Boolean;

   function Site (Of_Table : Table; Id : Declaration_Id) return Origin
     with Pre => Contains (Of_Table, Id);

private

   package Origin_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Origin);

   type Table is tagged limited record
      Items : Origin_Vectors.Vector;
   end record;

end Landin.Provenance;
