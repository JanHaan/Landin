package body Landin.Checking is

   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Byte_Count;

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Table : Table) return Boolean
     is (Of_Table.Ready);

   function Source_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Runs.Length));

   function Node_Limit
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     is (if Id /= Landin.Source.No_Source
           and then Natural (Id) <= Source_Count (Of_Table)
         then Of_Table.Runs (Positive (Id)).Count
         else 0);

   function Declaration_Limit (Of_Table : Table) return Natural
     is (Natural (Of_Table.Declarations.Length));

   function Covers (Of_Table : Table; Of_Tree : Landin.Syntax.Tree)
     return Boolean
     is (Node_Limit (Of_Table, Landin.Syntax.Source_Of (Of_Tree))
         = Landin.Syntax.Node_Count (Of_Tree));

   procedure Prepare
     (Into      : in out Table;
      Trees     : Landin.Syntax.Forest.Table;
      Meanings  : Landin.Resolution.Table;
      Spellings : in out Landin.Source.Names.Table) is
   begin
      for Index in 1 .. Landin.Syntax.Forest.Count (Trees) loop
         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees, Landin.Source.Source_Id (Index));
            Held    : constant Natural :=
              Landin.Syntax.Node_Count (Of_Tree.all);
         begin
            Into.Runs.Append
              (Run'(First => Natural (Into.Node_Types.Length),
                    Count => Held));

            for Unused in 1 .. Held loop
               Into.Node_Types.Append (Landin.Types.Undecided);
               Into.Node_Bodies.Append (Landin.Provenance.No_Declaration);
               Into.Node_Fields.Append (0);
               Into.Node_Shapes.Append (Array_Shape'(others => <>));
            end loop;
         end;
      end loop;

      for Unused in 1 .. Landin.Resolution.Declaration_Count (Meanings) loop
         Into.Declarations.Append (Settlement'(others => <>));
         Into.Layouts.Append (Aggregate_Layout'(others => <>));
         Into.Shapes.Append (Array_Shape'(others => <>));
      end loop;

      --  Interned once, so a Type_Name node costs eleven integer
      --  comparisons and never a byte comparison.
      for Item in Landin.Types.Scalar_Name loop
         Into.Scalars (Item) :=
           Landin.Source.Names.Intern
             (Spellings, Landin.Types.Spelling (Item));
      end loop;

      Into.Ready := True;
   end Prepare;

   ------------------------------------------------------------------
   --  The eleven, by identity
   ------------------------------------------------------------------

   function Named (Of_Table : Table; Id : Landin.Source.Names.Name_Id)
     return Landin.Types.Type_Kind is
   begin
      for Item in Landin.Types.Scalar_Name loop
         if Of_Table.Scalars (Item) = Id then
            return Item;
         end if;
      end loop;

      return Landin.Types.Ill_Typed;
   end Named;

   ------------------------------------------------------------------
   --  What a node has
   ------------------------------------------------------------------

   --  Where a node's entry sits: the run of its source, plus its index.
   function Slot
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Positive
     is (Of_Table.Runs
           (Positive (Landin.Syntax.Source_Of (Of_Tree))).First
         + Positive (Node));

   function Type_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Landin.Types.Type_Kind
     is (Of_Table.Node_Types (Slot (Of_Table, Of_Tree, Node)));

   function Body_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id)
     return Landin.Provenance.Declaration_Id
     is (Of_Table.Node_Bodies (Slot (Of_Table, Of_Tree, Node)));

   function Body_Of
     (Of_Table : Table; Id : Landin.Provenance.Declaration_Id)
     return Landin.Provenance.Declaration_Id
     is (if Id /= Landin.Provenance.No_Declaration
           and then Natural (Id) <= Natural (Of_Table.Bodies.Length)
         then Of_Table.Bodies (Natural (Id))
         else Landin.Provenance.No_Declaration);

   procedure Note_Body
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Wrote   : Landin.Provenance.Declaration_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Node_Bodies (Where) /= Landin.Provenance.No_Declaration
        and then Into.Node_Bodies (Where) /= Wrote
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two aggregate type identities";
      end if;

      Into.Node_Bodies (Where) := Wrote;
   end Note_Body;

   procedure Note_Body
     (Into  : in out Table;
      Id    : Landin.Provenance.Declaration_Id;
      Wrote : Landin.Provenance.Declaration_Id) is
   begin
      while Natural (Into.Bodies.Length) < Natural (Id) loop
         Into.Bodies.Append (Landin.Provenance.No_Declaration);
      end loop;

      if Into.Bodies (Natural (Id)) /= Landin.Provenance.No_Declaration
        and then Into.Bodies (Natural (Id)) /= Wrote
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two aggregate type identities";
      end if;

      Into.Bodies (Natural (Id)) := Wrote;
   end Note_Body;

   ------------------------------------------------------------------
   --  How an aggregate is laid out
   ------------------------------------------------------------------

   function Has_Layout (Of_Table : Table; Id : Declaration_Id)
     return Boolean
   is
      From : constant Declaration_Id := Body_Of (Of_Table, Id);
   begin
      return From /= No_Declaration
        and then Of_Table.Layouts (Natural (From)).Ready;
   end Has_Layout;

   function Layout_Field_Count (Of_Table : Table; Id : Declaration_Id)
     return Natural
     is (Of_Table.Layouts
           (Natural (Body_Of (Of_Table, Id))).Count);

   procedure Lay_Out
     (Into  : in out Table;
      Id    : Declaration_Id;
      Fields : Field_Shape_Array;
      Facts : Landin.Targets.Target_Facts;
      Fits  : out Boolean)
   is
      Built : Aggregate_Layout;

      procedure Extent_Of
        (Field     : Field_Shape;
         Size      : out Landin.Targets.Byte_Count;
         Alignment : out Landin.Targets.Byte_Alignment);

      procedure Extent_Of
        (Field     : Field_Shape;
         Size      : out Landin.Targets.Byte_Count;
         Alignment : out Landin.Targets.Byte_Alignment)
      is
         Held : constant Landin.Targets.Scalar_Size :=
           Landin.Types.Storage_Size (Field.Element, Facts);
      begin
         if Field.Kind = Scalar_Field then
            Size := Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
            Alignment := Landin.Targets.Alignment_Of (Facts, Held);
         else
            Array_Extent
              (Field.Length, Field.Element, Facts, Size, Alignment);
         end if;
      end Extent_Of;
   begin
      --  First prove the complete padded value fits this target.  D18 proves
      --  each array leaf fits alone; the containing struct still may not.
      for Field in Fields'Range loop
         declare
            Size      : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            Ignored   : Landin.Targets.Byte_Count;
         begin
            Extent_Of (Fields (Field), Size, Alignment);
            if not Landin.Targets.Can_Place
                     (Built.Placed, Size, Alignment,
                      Landin.Targets.Maximum_Object_Size (Facts))
            then
               Fits := False;
               return;
            end if;
            Landin.Targets.Place
              (Built.Placed, Size, Alignment, Ignored);
         end;
      end loop;

      Built.First := Natural (Into.Field_Offsets.Length) + 1;
      Built.Count := Fields'Length;
      Built.Placed := Landin.Targets.Empty_Placement;

      for Field in Fields'Range loop
         declare
            Size      : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            At_Offset : Landin.Targets.Byte_Count;
         begin
            Extent_Of (Fields (Field), Size, Alignment);
            Landin.Targets.Place
              (Built.Placed, Size, Alignment, At_Offset);
            Into.Field_Offsets.Append (At_Offset);
            Into.Field_Shapes.Append (Fields (Field));
         end;
      end loop;

      Built.Ready := True;
      Into.Layouts (Natural (Id)) := Built;
      Fits := True;
   end Lay_Out;

   function Has_Only_Scalar_Fields
     (Of_Table : Table; Id : Declaration_Id) return Boolean
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      for Field in 1 .. Layout.Count loop
         if Of_Table.Field_Shapes (Layout.First + Field - 1).Kind
              /= Scalar_Field
         then
            return False;
         end if;
      end loop;
      return True;
   end Has_Only_Scalar_Fields;

   function Field_Offset
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Targets.Byte_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Offsets (Layout.First + Field - 1);
   end Field_Offset;

   function Field_Type
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes (Layout.First + Field - 1).Element;
   end Field_Type;

   function Field_Kind_Of
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Field_Kind
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes (Layout.First + Field - 1).Kind;
   end Field_Kind_Of;

   function Field_Array_Length
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Element_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes (Layout.First + Field - 1).Length;
   end Field_Array_Length;

   function Field_Array_Element
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes (Layout.First + Field - 1).Element;
   end Field_Array_Element;

   function Layout_Extent (Of_Table : Table; Id : Declaration_Id)
     return Landin.Targets.Byte_Count
     is (Landin.Targets.Extent_Of
           (Of_Table.Layouts
              (Natural (Body_Of (Of_Table, Id))).Placed));

   function Layout_Alignment (Of_Table : Table; Id : Declaration_Id)
     return Landin.Targets.Byte_Alignment
     is (Landin.Targets.Alignment_Of
           (Of_Table.Layouts
              (Natural (Body_Of (Of_Table, Id))).Placed));

   function Layout_Size (Of_Table : Table; Id : Declaration_Id)
     return Landin.Targets.Byte_Count
     is (Landin.Targets.Size_Of
           (Of_Table.Layouts
              (Natural (Body_Of (Of_Table, Id))).Placed));

   function Field_Index
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Natural
     is (Of_Table.Node_Fields (Slot (Of_Table, Of_Tree, Node)));

   procedure Note_Field
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Which   : Positive) is
   begin
      Into.Node_Fields (Slot (Into, Of_Tree, Node)) := Which;
   end Note_Field;

   function Array_Length
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Element_Count
     is (Of_Table.Node_Shapes (Slot (Of_Table, Of_Tree, Node)).Length);

   function Array_Element
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Landin.Types.Scalar_Name
     is (Of_Table.Node_Shapes (Slot (Of_Table, Of_Tree, Node)).Element);

   procedure Note_Array
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Length  : Element_Count;
      Element : Landin.Types.Scalar_Name) is
   begin
      Into.Node_Shapes (Slot (Into, Of_Tree, Node)) :=
        Array_Shape'(Length => Length, Element => Element);
   end Note_Array;

   function Array_Length
     (Of_Table : Table; Id : Declaration_Id) return Element_Count
     is (Of_Table.Shapes (Natural (Id)).Length);

   function Array_Element
     (Of_Table : Table; Id : Declaration_Id)
     return Landin.Types.Scalar_Name
     is (Of_Table.Shapes (Natural (Id)).Element);

   procedure Note_Array
     (Into    : in out Table;
      Id      : Declaration_Id;
      Length  : Element_Count;
      Element : Landin.Types.Scalar_Name) is
   begin
      Into.Shapes (Natural (Id)) :=
        Array_Shape'(Length => Length, Element => Element);
   end Note_Array;

   procedure Array_Extent
     (Length    : Element_Count;
      Element   : Landin.Types.Scalar_Name;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Held : constant Landin.Targets.Scalar_Size :=
        Landin.Types.Storage_Size (Element, Facts);
   begin
      Alignment :=
        (if Length = 0 then 1
         else Landin.Targets.Alignment_Of (Facts, Held));
      Size :=
        Landin.Targets.Byte_Count (Length)
        * Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
   end Array_Extent;

   procedure Note
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Item    : Landin.Types.Type_Kind) is
   begin
      Into.Node_Types (Slot (Into, Of_Tree, Node)) := Item;
   end Note;

   procedure Commit
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      To      : Landin.Types.Scalar_Name) is
   begin
      Into.Node_Types (Slot (Into, Of_Tree, Node)) := To;
   end Commit;

   procedure Refuse
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id) is
   begin
      Into.Node_Types (Slot (Into, Of_Tree, Node)) :=
        Landin.Types.Ill_Typed;
   end Refuse;

   ------------------------------------------------------------------
   --  What a declaration has
   ------------------------------------------------------------------

   function State_Of (Of_Table : Table; Id : Declaration_Id)
     return Progress
     is (Of_Table.Declarations (Positive (Id)).State);

   function Type_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Types.Type_Kind
     is (Of_Table.Declarations (Positive (Id)).Answer);

   procedure Begin_Inference
     (Into : in out Table; Id : Declaration_Id) is
   begin
      Into.Declarations (Positive (Id)).State := Underway;
   end Begin_Inference;

   procedure Settle
     (Into : in out Table;
      Id   : Declaration_Id;
      Item : Landin.Types.Type_Kind) is
   begin
      Into.Declarations (Positive (Id)) :=
        Settlement'(State => Settled, Answer => Item);
   end Settle;

end Landin.Checking;
