--  D139's immutable selected-declaration view.  Syntax remains complete;
--  this compilation-owned table only records nodes beneath inactive arms.

private with Ada.Containers.Vectors;

with Landin.Source;
with Landin.Syntax;

package Landin.Configuration is

   type Table is private;

   procedure Prepare (Into : in out Table);

   procedure Mark_Inactive
     (Into : in out Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id);

   function Is_Active
     (In_Table : Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) return Boolean;

   --  D139 presents selected declarations as one module declaration run.
   --  Stages use this instead of walking fixed-conditionals themselves, so
   --  nesting and inactive arms have one interpretation throughout.
   generic
      with procedure Action
        (Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id);
   procedure For_Each_Active_Declaration
     (In_Table : Table; Of_Tree : Landin.Syntax.Tree);

private

   type Inactive_Node is record
      Source : Landin.Source.Source_Id;
      Node   : Landin.Syntax.Node_Id;
   end record;

   package Entries is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Inactive_Node);

   type Table is record
      Inactive : Entries.Vector;
   end record;

end Landin.Configuration;
