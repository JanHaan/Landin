package body Landin.Configuration is

   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Source.Names.Name_Id;

   function Is_Builtin_Import
     (Names : Landin.Source.Names.Table;
      Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Boolean
   is
      function Segment (Index : Positive) return String
        is (Landin.Source.Names.Spelling (Names, Landin.Syntax.Name
          (Of_Tree, Landin.Syntax.Nth_Import_Segment (Of_Tree, Node, Index))));
   begin
      return Landin.Syntax.Import_Segment_Count (Of_Tree, Node) = 2
        and then Segment (1) = "landin"
        and then Segment (2) in "compiler" | "assembler" | "linker";
   end Is_Builtin_Import;

   function Tool_Advice (Namespace, Member : String) return String is
   begin
      if Namespace = "assembler" and then Member = "block" then
         return "[1630]: assembler.block is enabled by R6.60";
      elsif Namespace = "compiler" and then Member'Length >= 7
        and then Member (Member'First .. Member'First + 6) = "atomic_"
      then
         return "[1620]: compiler." & Member & " is enabled by R6.30";
      elsif Namespace = "compiler" and then Member'Length >= 7
        and then Member (Member'First .. Member'First + 6) = "vector_"
      then
         return "[0590]: compiler." & Member & " is enabled by R4.50";
      elsif Namespace = "linker" and then Member in "section" | "entry" then
         return "[1640]: linker." & Member & " is enabled by R6.60";
      elsif (Namespace = "compiler" and then Member = "assert")
        or else (Namespace = "linker" and then Member = "library")
      then
         return "D202: " & Namespace & "." & Member
           & " is a module-only fixed directive";
      elsif Namespace = "compiler" and then Member
        in "arch" | "word_size" | "byte_order" | "build_mode"
      then
         return "D202: compiler." & Member
           & " is available only in fixed configuration expressions";
      else
         return "[1560]: unknown builtin member " & Namespace & "." & Member;
      end if;
   end Tool_Advice;

   procedure Record_Option
     (Into : in out Table; Name : Landin.Source.Names.Name_Id;
      Origin : Landin.Provenance.Origin) is
   begin
      Into.Declared.Append (Option_Site'(Name, Origin));
   end Record_Option;

   function Option_Origin
     (In_Table : Table; Name : Landin.Source.Names.Name_Id)
      return Landin.Provenance.Origin is
   begin
      for Item of In_Table.Declared loop
         if Item.Name = Name then
            return Item.Origin;
         end if;
      end loop;
      return Landin.Provenance.No_Origin;
   end Option_Origin;

   procedure Set_Mode (Into : in out Table; Mode : Build_Mode) is
   begin
      Into.Selected_Mode := Mode;
   end Set_Mode;

   function Mode (In_Table : Table) return Build_Mode
     is (In_Table.Selected_Mode);

   procedure Add_Override
     (Into : in out Table; Name : String; Value : String) is
   begin
      Into.Settings.Append
        (Override_Entry'
           (Ada.Strings.Unbounded.To_Unbounded_String (Name),
            Ada.Strings.Unbounded.To_Unbounded_String (Value)));
   end Add_Override;

   function Override_Count (In_Table : Table) return Natural
     is (Natural (In_Table.Settings.Length));

   function Override_Name
     (In_Table : Table; Index : Positive) return String
     is (Ada.Strings.Unbounded.To_String
           (In_Table.Settings.Element (Index).Name));

   function Override_Value
     (In_Table : Table; Index : Positive) return String
     is (Ada.Strings.Unbounded.To_String
           (In_Table.Settings.Element (Index).Value));

   procedure Add_Library (Into : in out Table; Name : String) is
   begin
      Into.Linked.Append (Name);
   end Add_Library;

   function Library_Count (In_Table : Table) return Natural
     is (Natural (In_Table.Linked.Length));

   function Library_Name
     (In_Table : Table; Index : Positive) return String
     is (In_Table.Linked.Element (Index));

   procedure Prepare (Into : in out Table) is
   begin
      Into.Inactive.Clear;
      Into.Linked.Clear;
      Into.Declared.Clear;
   end Prepare;

   procedure Mark_Inactive
     (Into : in out Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) is
   begin
      Into.Inactive.Append
        (Inactive_Node'(Source => Source, Node => Node));
   end Mark_Inactive;

   function Is_Active
     (In_Table : Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) return Boolean is
   begin
      for Item of In_Table.Inactive loop
         if Item.Source = Source and then Item.Node = Node then
            return False;
         end if;
      end loop;
      return True;
   end Is_Active;

   procedure For_Each_Active_Declaration
     (In_Table : Table; Of_Tree : Landin.Syntax.Tree)
   is
      procedure Visit (Node : Landin.Syntax.Node_Id);

      procedure Visit (Node : Landin.Syntax.Node_Id) is
      begin
         if not Is_Active (In_Table, Landin.Syntax.Source_Of (Of_Tree), Node)
         then
            return;
         end if;

         if Landin.Syntax.Kind (Of_Tree, Node)
              = Landin.Syntax.Fixed_Conditional
         then
            for Arm in 1 .. Landin.Syntax.Fixed_Arm_Count (Of_Tree, Node)
            loop
               declare
                  This : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Nth_Fixed_Arm (Of_Tree, Node, Arm);
               begin
                  for Which in 1 .. Landin.Syntax.Fixed_Declaration_Count
                    (Of_Tree, This)
                  loop
                     Visit (Landin.Syntax.Nth_Fixed_Declaration
                       (Of_Tree, This, Which));
                  end loop;
               end;
            end loop;
         else
            Action (Of_Tree, Node);
         end if;
      end Visit;
   begin
      for Position in 1 .. Landin.Syntax.Declaration_Count (Of_Tree) loop
         Visit (Landin.Syntax.Nth_Declaration (Of_Tree, Position));
      end loop;
   end For_Each_Active_Declaration;

end Landin.Configuration;
