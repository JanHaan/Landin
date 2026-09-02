--  The reached module graph selected from ordered import roots.
--
--  This is target-neutral topology, not host discovery.  The driver asks the
--  filesystem which directory an import selects and records that answer;
--  semantic stages consume identities and never read a path from the host.

private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;

with Landin.Source;
with Landin.Syntax;

package Landin.Modules is

   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;

   type Module_Id is range 0 .. Integer'Last;

   No_Module    : constant Module_Id := 0;
   Entry_Module : constant Module_Id := 1;

   type Table is tagged limited private;

   function Module_Count (Of_Table : Table) return Natural;

   function Contains (Of_Table : Table; Id : Module_Id) return Boolean
     is (Id /= No_Module
         and then Natural (Id) <= Module_Count (Of_Table));

   function Source_Count (Of_Table : Table) return Natural;

   function Module_Of
     (Of_Table : Table; Source : Landin.Source.Source_Id) return Module_Id
     with Pre  => Source /= Landin.Source.No_Source
                  and then Natural (Source) <= Source_Count (Of_Table),
          Post => Contains (Of_Table, Module_Of'Result);

   --  Create the stable entry identity before any source is attached.  The
   --  empty paths are the explicit-file compatibility module; the rooted
   --  driver replaces them with the real entry directory before loading it.
   procedure Initialize (Into : in out Table)
     with Pre  => Module_Count (Into) = 0,
          Post => Module_Count (Into) = 1
                  and then Contains (Into, Entry_Module);

   procedure Set_Entry_Directory
     (Into     : in out Table;
      Directory : String)
     with Pre  => Contains (Into, Entry_Module)
                  and then Directory /= ""
                  and then Source_Count (Into) = 0,
          Post => Directory_Path (Into, Entry_Module) = Directory;

   function Find_Logical (Of_Table : Table; Logical : String) return Module_Id;

   function Find_Directory
     (Of_Table : Table; Directory : String) return Module_Id;

   function Add_Module
     (Into       : in out Table;
      Logical    : String;
      Directory  : String;
      Root_Index : Positive) return Module_Id
     with Pre  => Contains (Into, Entry_Module)
                  and then Logical /= ""
                  and then Directory /= ""
                  and then Find_Logical (Into, Logical) = No_Module
                  and then Find_Directory (Into, Directory) = No_Module,
          Post => Module_Count (Into) = Module_Count (Into)'Old + 1
                  and then Contains (Into, Add_Module'Result);

   function Logical_Path (Of_Table : Table; Id : Module_Id) return String
     with Pre => Contains (Of_Table, Id);

   function Directory_Path (Of_Table : Table; Id : Module_Id) return String
     with Pre => Contains (Of_Table, Id);

   function Root_Ordinal (Of_Table : Table; Id : Module_Id) return Natural
     with Pre => Contains (Of_Table, Id);

   --  Source identities are attached in the reached program's canonical
   --  order: entry first, sorted files, source-order imports and FIFO module
   --  discovery.  All later stages retain that order by walking Source_Id.
   procedure Attach_Source
     (Into   : in out Table;
      Source : Landin.Source.Source_Id;
      Module : Module_Id)
     with Pre  => Contains (Into, Module)
                  and then Source /= Landin.Source.No_Source
                  and then Natural (Source) = Source_Count (Into) + 1,
          Post => Source_Count (Into) = Source_Count (Into)'Old + 1
                  and then Module_Of (Into, Source) = Module;

   --  One selection per import syntax node.  Discovery records this only
   --  after a root wins; resolution consumes the chosen module identity.
   function Imported_Module
     (Of_Table : Table;
      Source   : Landin.Source.Source_Id;
      Node     : Landin.Syntax.Node_Id) return Module_Id;

   procedure Record_Import
     (Into   : in out Table;
      Source : Landin.Source.Source_Id;
      Node   : Landin.Syntax.Node_Id;
      Target : Module_Id)
     with Pre  => Contains (Into, Target)
                  and then Source /= Landin.Source.No_Source
                  and then Natural (Source) <= Source_Count (Into)
                  and then Node /= Landin.Syntax.No_Node
                  and then Imported_Module (Into, Source, Node) = No_Module,
          Post => Imported_Module (Into, Source, Node) = Target;

private

   type Module_Record is record
      Logical    : Ada.Strings.Unbounded.Unbounded_String;
      Directory  : Ada.Strings.Unbounded.Unbounded_String;
      Root_Index : Natural := 0;
   end record;

   package Module_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Module_Record);

   package Source_Module_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Module_Id);

   type Import_Record is record
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Node   : Landin.Syntax.Node_Id := Landin.Syntax.No_Node;
      Target : Module_Id := No_Module;
   end record;

   package Import_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Import_Record);

   type Table is tagged limited record
      Modules : Module_Vectors.Vector;
      Sources : Source_Module_Vectors.Vector;
      Imports : Import_Vectors.Vector;
   end record;

end Landin.Modules;
