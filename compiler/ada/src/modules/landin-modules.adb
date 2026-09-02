package body Landin.Modules is

   package Unbounded renames Ada.Strings.Unbounded;

   function Module_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Modules.Length));

   function Source_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Sources.Length));

   procedure Initialize (Into : in out Table) is
   begin
      Into.Modules.Append
        (Module_Record'
           (Logical    => Unbounded.Null_Unbounded_String,
            Directory  => Unbounded.Null_Unbounded_String,
            Root_Index => 0));
   end Initialize;

   procedure Set_Entry_Directory
     (Into     : in out Table;
      Directory : String) is
   begin
      Into.Modules.Replace_Element
        (Positive (Entry_Module),
         Module_Record'
           (Logical    => Unbounded.Null_Unbounded_String,
            Directory  => Unbounded.To_Unbounded_String (Directory),
            Root_Index => 0));
   end Set_Entry_Directory;

   function Find_Logical (Of_Table : Table; Logical : String) return Module_Id
   is
   begin
      for Index in 1 .. Module_Count (Of_Table) loop
         if Unbounded.To_String
              (Of_Table.Modules.Element (Index).Logical) = Logical
         then
            return Module_Id (Index);
         end if;
      end loop;
      return No_Module;
   end Find_Logical;

   function Find_Directory
     (Of_Table : Table; Directory : String) return Module_Id
   is
   begin
      for Index in 1 .. Module_Count (Of_Table) loop
         if Unbounded.To_String
              (Of_Table.Modules.Element (Index).Directory) = Directory
         then
            return Module_Id (Index);
         end if;
      end loop;
      return No_Module;
   end Find_Directory;

   function Add_Module
     (Into       : in out Table;
      Logical    : String;
      Directory  : String;
      Root_Index : Positive) return Module_Id
   is
   begin
      Into.Modules.Append
        (Module_Record'
           (Logical    => Unbounded.To_Unbounded_String (Logical),
            Directory  => Unbounded.To_Unbounded_String (Directory),
            Root_Index => Root_Index));
      return Module_Id (Into.Modules.Length);
   end Add_Module;

   function Logical_Path (Of_Table : Table; Id : Module_Id) return String
     is (Unbounded.To_String
           (Of_Table.Modules.Element (Positive (Id)).Logical));

   function Directory_Path (Of_Table : Table; Id : Module_Id) return String
     is (Unbounded.To_String
           (Of_Table.Modules.Element (Positive (Id)).Directory));

   function Root_Ordinal (Of_Table : Table; Id : Module_Id) return Natural
     is (Of_Table.Modules.Element (Positive (Id)).Root_Index);

   procedure Attach_Source
     (Into   : in out Table;
      Source : Landin.Source.Source_Id;
      Module : Module_Id) is
   begin
      Into.Sources.Append (Module);
   end Attach_Source;

   function Module_Of
     (Of_Table : Table; Source : Landin.Source.Source_Id) return Module_Id
     is (Of_Table.Sources.Element (Positive (Source)));

   function Imported_Module
     (Of_Table : Table;
      Source   : Landin.Source.Source_Id;
      Node     : Landin.Syntax.Node_Id) return Module_Id
   is
   begin
      for Item of Of_Table.Imports loop
         if Item.Source = Source and then Item.Node = Node then
            return Item.Target;
         end if;
      end loop;
      return No_Module;
   end Imported_Module;

   procedure Record_Import
     (Into   : in out Table;
      Source : Landin.Source.Source_Id;
      Node   : Landin.Syntax.Node_Id;
      Target : Module_Id) is
   begin
      Into.Imports.Append
        (Import_Record'(Source => Source, Node => Node, Target => Target));
   end Record_Import;

end Landin.Modules;
