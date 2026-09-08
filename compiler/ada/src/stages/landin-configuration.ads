--  D139/D202 configuration metadata. Syntax remains complete; this table
--  retains request overrides and mode, and records option provenance,
--  inactive declarations and ordered library requests for one compilation.

private with Ada.Containers.Vectors;
private with Ada.Containers.Indefinite_Vectors;
private with Ada.Strings.Unbounded;

with Landin.Source;
with Landin.Source.Names;
with Landin.Provenance;
with Landin.Syntax;

package Landin.Configuration is

   type Table is private;

   type Build_Mode is (Debug, Release);
   procedure Set_Mode (Into : in out Table; Mode : Build_Mode);
   function Mode (In_Table : Table) return Build_Mode;

   --  Shared explanation for a tool member outside its enabled context.
   function Tool_Advice (Namespace, Member : String) return String;

   function Is_Builtin_Import
     (Names : Landin.Source.Names.Table;
      Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Boolean;

   procedure Record_Option
     (Into : in out Table; Name : Landin.Source.Names.Name_Id;
      Origin : Landin.Provenance.Origin);
   function Option_Origin
     (In_Table : Table; Name : Landin.Source.Names.Name_Id)
      return Landin.Provenance.Origin;

   --  Request inputs survive Prepare; outputs are rebuilt for each run.
   procedure Add_Override
     (Into : in out Table; Name : String; Value : String);
   function Override_Count (In_Table : Table) return Natural;
   function Override_Name
     (In_Table : Table; Index : Positive) return String;
   function Override_Value
     (In_Table : Table; Index : Positive) return String;

   procedure Add_Library (Into : in out Table; Name : String);
   function Library_Count (In_Table : Table) return Natural;
   function Library_Name
     (In_Table : Table; Index : Positive) return String;

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

   type Override_Entry is record
      Name, Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Overrides is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Override_Entry);
   package Libraries is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);
   type Option_Site is record
      Name : Landin.Source.Names.Name_Id;
      Origin : Landin.Provenance.Origin;
   end record;
   package Option_Sites is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Option_Site);

   type Table is record
      Inactive : Entries.Vector;
      Settings : Overrides.Vector;
      Linked   : Libraries.Vector;
      Declared : Option_Sites.Vector;
      Selected_Mode : Build_Mode := Debug;
   end record;

end Landin.Configuration;
