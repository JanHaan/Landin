with Landin.Tokens.Text;

package body Landin.Configuration is

   use type Landin.Source.Source_Id;
   use type Landin.Source.Span;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Source.Names.Name_Id;

   function Compiler_Member
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return String
   is
      package Syn renames Landin.Syntax;
   begin
      if Node /= Syn.No_Node
        and then Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
        and then Syn.Kind (Of_Tree, Syn.Target_Of (Of_Tree, Node))
          = Syn.Name_Reference
        and then Landin.Source.Names.Spelling
          (Names, Syn.Name (Of_Tree, Syn.Target_Of (Of_Tree, Node)))
            = "compiler"
      then
         return Landin.Source.Names.Spelling
           (Names, Syn.Name (Of_Tree, Node));
      end if;
      return "";
   end Compiler_Member;

   function Assembly_Call
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return Boolean
   is
      package Syn renames Landin.Syntax;
      Callee : Syn.Node_Id;
   begin
      if Node = Syn.No_Node or else Syn.Kind (Of_Tree, Node) /= Syn.Call then
         return False;
      end if;
      Callee := Syn.Callee_Of (Of_Tree, Node);
      return Syn.Kind (Of_Tree, Callee) = Syn.Member_Selection
        and then Syn.Kind (Of_Tree, Syn.Target_Of (Of_Tree, Callee))
          = Syn.Name_Reference
        and then Landin.Source.Names.Spelling
          (Names, Syn.Name (Of_Tree, Syn.Target_Of (Of_Tree, Callee)))
            = "assembler"
        and then Landin.Source.Names.Spelling
          (Names, Syn.Name (Of_Tree, Callee)) = "block";
   end Assembly_Call;

   function Fixed_Text
     (Snapshot : Landin.Source.Snapshot; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return String
   is
      Lexeme : constant String := Landin.Source.Slice
        (Snapshot, Landin.Syntax.Anchor (Of_Tree, Node));
      Units : Landin.Tokens.Text.Code_Unit_Array (1 .. Lexeme'Length);
      Count, First, Last : Natural;
      Fault : Landin.Tokens.Text.Problem;
      use type Landin.Tokens.Text.Problem;
   begin
      Landin.Tokens.Text.Decode_View
        (Lexeme,
         Landin.Syntax.Kind (Of_Tree, Node) = Landin.Syntax.Raw_Literal,
         Landin.Tokens.Text.Byte_Units, Units, Count, Fault, First, Last);
      if Fault /= Landin.Tokens.Text.Well_Formed then
         return "";
      end if;
      declare
         Result : String (1 .. Count);
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val (Units (Index));
         end loop;
         return Result;
      end;
   end Fixed_Text;

   function Placement_Of
     (Snapshot : Landin.Source.Snapshot; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id; Names : in out Landin.Source.Names.Table)
      return Landin.Machine.Placement
   is
      Attr : constant Landin.Syntax.Machine_Attributes :=
        Landin.Syntax.Attributes (Of_Tree, Node);
      Result : Landin.Machine.Placement;
      function Number (At_Span : Landin.Source.Span) return Natural;
      function Number (At_Span : Landin.Source.Span) return Natural is
         Text : constant String := Landin.Source.Slice (Snapshot, At_Span);
         Value : Natural := 0;
      begin
         for C of Text loop
            if C = '_' then
               null;
            elsif C not in '0' .. '9' or else Value > 256 then
               return Natural'Last;
            else
               Value := Value * 10 + Character'Pos (C) - Character'Pos ('0');
            end if;
         end loop;
         return Value;
      end Number;
   begin
      Result.Keep := Attr.Keep;
      Result.Alignment := Number (Attr.Alignment);
      Result.Vector := Number (Attr.Vector);
      if Attr.Section /= Landin.Source.Empty_Span then
         declare
            Text : constant String := Landin.Source.Slice
              (Snapshot, Attr.Section);
         begin
            Result.Section := Landin.Source.Names.Intern
              (Names, Text (Text'First + 1 .. Text'Last - 1));
         end;
      end if;
      return Result;
   end Placement_Of;

   function Memory_Call
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return Landin.Memory.Operation is
   begin
      if Node /= Landin.Syntax.No_Node
        and then Landin.Syntax.Kind (Of_Tree, Node) = Landin.Syntax.Call
      then
         return Landin.Memory.Named (Compiler_Member
           (Names, Of_Tree, Landin.Syntax.Callee_Of (Of_Tree, Node)));
      end if;
      return Landin.Memory.No_Operation;
   end Memory_Call;

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
         return "[1990]: assembler.block is called in a Cortex-M0 routine"
           & " body";
      elsif Namespace = "compiler" and then Member'Length >= 7
        and then Member (Member'First .. Member'First + 6) = "atomic_"
      then
         return "[1620]/D227: compiler." & Member
           & " is not one of the memory operations";
      elsif Namespace = "compiler" and then Member'Length >= 7
        and then Member (Member'First .. Member'First + 6) = "vector_"
      then
         --  D240: fixed arrays are the vector type, so the vector
         --  intrinsics [1560] once listed are withdrawn rather than
         --  duplicate the element-wise operators D209 implements.
         return "[0590]/D240: compiler." & Member
           & " is withdrawn; fixed arrays take element-wise operators";
      elsif Namespace = "linker" and then Member in "section" | "entry" then
         return "[1640]/D229: use link(section: ...) or "
           & "--firmware-entry; linker." & Member
           & " is not a module-call directive";
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
