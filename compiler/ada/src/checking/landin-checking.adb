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
               Into.Node_Signatures.Append (No_Signature);
               Into.Node_Fields.Append (0);
               Into.Node_Shapes.Append (Array_Shape'(others => <>));
            end loop;
         end;
      end loop;

      for Unused in 1 .. Landin.Resolution.Declaration_Count (Meanings) loop
         Into.Declarations.Append (Settlement'(others => <>));
         Into.Layouts.Append (Aggregate_Layout'(others => <>));
         Into.Shapes.Append (Array_Shape'(others => <>));
         Into.Declaration_Signatures.Append (No_Signature);
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
   --  Function signatures
   ------------------------------------------------------------------

   function Signature_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Signatures.Length));

   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Result     : Signature_Part;
      Site       : Landin.Provenance.Origin) return Signature_Id
   is
      Made : Signature_Record :=
        (Parameters => (First => 0, Count => 0),
         Result     => Result,
         Site       => Site);
   begin
      if Parameters'Length > 0 then
         Made.Parameters.First := Natural (Into.Signature_Parts.Length);
         for Part of Parameters loop
            Into.Signature_Parts.Append (Part);
            Made.Parameters.Count := Made.Parameters.Count + 1;
         end loop;
      end if;

      Into.Signatures.Append (Made);
      return Signature_Id (Into.Signatures.Last_Index);
   end Add_Signature;

   function Signature_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Signature_Id
     is (Of_Table.Node_Signatures (Slot (Of_Table, Of_Tree, Node)));

   function Signature_Of
     (Of_Table : Table; Id : Declaration_Id) return Signature_Id
     is (if Id = No_Declaration then No_Signature
         else Of_Table.Declaration_Signatures (Positive (Id)));

   procedure Note_Signature
     (Into      : in out Table;
      Of_Tree   : Landin.Syntax.Tree;
      Node      : Landin.Syntax.Node_Id;
      Signature : Signature_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Node_Signatures (Where) /= No_Signature
        and then Into.Node_Signatures (Where) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two function signatures";
      end if;
      Into.Node_Signatures (Where) := Signature;
   end Note_Signature;

   procedure Note_Signature
     (Into      : in out Table;
      Id        : Declaration_Id;
      Signature : Signature_Id) is
   begin
      if Into.Declaration_Signatures (Positive (Id)) /= No_Signature
        and then Into.Declaration_Signatures (Positive (Id)) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two function signatures";
      end if;
      Into.Declaration_Signatures (Positive (Id)) := Signature;
   end Note_Signature;

   function Signature_Parameter_Count
     (Of_Table : Table; Signature : Signature_Id) return Natural
     is (Of_Table.Signatures (Positive (Signature)).Parameters.Count);

   function Nth_Signature_Parameter
     (Of_Table : Table; Signature : Signature_Id; Index : Positive)
      return Signature_Part
   is
      Parameters : constant Run :=
        Of_Table.Signatures (Positive (Signature)).Parameters;
   begin
      return Of_Table.Signature_Parts (Parameters.First + Index);
   end Nth_Signature_Parameter;

   function Signature_Result
     (Of_Table : Table; Signature : Signature_Id) return Signature_Part
     is (Of_Table.Signatures (Positive (Signature)).Result);

   function Signature_Origin
     (Of_Table : Table; Signature : Signature_Id)
      return Landin.Provenance.Origin
     is (Of_Table.Signatures (Positive (Signature)).Site);

   function Signatures_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
   is
      function Parts_Agree (A, B : Signature_Part) return Boolean
        is (A.Kind = B.Kind
            and then
              (case A.Kind is
                  when Landin.Types.No_Value => True,
                  when Landin.Types.Scalar_Name => True,
                  when Landin.Types.Aggregate =>
                     A.Aggregate_Body = B.Aggregate_Body,
                  when Landin.Types.Fixed_Array =>
                     A.Length = B.Length and then A.Element = B.Element,
                  when others => False));
   begin
      if Signature_Parameter_Count (Of_Table, Left)
           /= Signature_Parameter_Count (Of_Table, Right)
        or else not Parts_Agree
          (Signature_Result (Of_Table, Left),
           Signature_Result (Of_Table, Right))
      then
         return False;
      end if;

      for Index in 1 .. Signature_Parameter_Count (Of_Table, Left) loop
         if not Parts_Agree
           (Nth_Signature_Parameter (Of_Table, Left, Index),
            Nth_Signature_Parameter (Of_Table, Right, Index))
         then
            return False;
         end if;
      end loop;
      return True;
   end Signatures_Agree;

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
      Fits  : out Boolean;
      Cases : Case_Run_Array := No_Case_Runs;
      Payloads : Field_Shape_Array := No_Field_Shapes)
   is
      Built : Aggregate_Layout;
      Layout_Possible : Boolean := True;

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
         elsif Field.Kind = Fixed_Array_Field then
            Array_Extent
              (Field.Length, Field.Element, Facts, Size, Alignment);
         elsif Field.Kind = Aggregate_Field then
            if Field.Aggregate_Body = No_Declaration
              or else not Contains (Into, Field.Aggregate_Body)
              or else not Has_Layout (Into, Field.Aggregate_Body)
            then
               raise Landin.Compiler_Defect with
                 "an aggregate field has no laid-out body";
            end if;
            Size := Layout_Size (Into, Field.Aggregate_Body);
            Alignment := Layout_Alignment (Into, Field.Aggregate_Body);
         else
            if Field.Cases = 0
              or else Field.Payloads_First = 0
              or else Field.Payloads_First > Cases'Length
              or else Field.Cases
                        > Cases'Length - Field.Payloads_First + 1
            then
               raise Landin.Compiler_Defect with
                 "a variant field has a malformed case run";
            end if;

            declare
               Payload_Size : Landin.Targets.Byte_Count := 0;
               Payload_Alignment : Landin.Targets.Byte_Alignment := 1;
               Tag_Size : constant Landin.Targets.Scalar_Size := Held;
               Tag_Bytes : constant Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count
                   (Landin.Targets.Bytes (Tag_Size));
               Part : Landin.Targets.Placement :=
                 Landin.Targets.Empty_Placement;
               Ignored : Landin.Targets.Byte_Count;
            begin
               for Which in 1 .. Field.Cases loop
                  declare
                     Run : constant Case_Run :=
                       Cases (Field.Payloads_First + Which - 1);
                     Placed : Landin.Targets.Placement :=
                       Landin.Targets.Empty_Placement;
                  begin
                     if Run.Count > 0
                       and then (Run.First = 0
                                 or else Run.First > Payloads'Length
                                 or else Run.Count
                                           > Payloads'Length - Run.First + 1)
                     then
                        raise Landin.Compiler_Defect with
                          "a variant payload has a malformed field run";
                     end if;

                     for Position in 1 .. Run.Count loop
                        declare
                           Part_Size : Landin.Targets.Byte_Count;
                           Part_Alignment : Landin.Targets.Byte_Alignment;
                        begin
                           if Payloads (Run.First + Position - 1).Kind
                                = Variant_Field
                           then
                              raise Landin.Compiler_Defect with
                                "a nested variant payload reached layout";
                           end if;
                           Extent_Of
                             (Payloads (Run.First + Position - 1),
                              Part_Size, Part_Alignment);
                           if not Landin.Targets.Can_Place
                             (Placed, Part_Size, Part_Alignment,
                              Landin.Targets.Maximum_Object_Size (Facts))
                           then
                              Layout_Possible := False;
                              Size := 0;
                              Alignment := 1;
                              return;
                           end if;
                           Landin.Targets.Place
                             (Placed, Part_Size, Part_Alignment, Ignored);
                        end;
                     end loop;

                     Payload_Size := Landin.Targets.Byte_Count'Max
                       (Payload_Size, Landin.Targets.Size_Of (Placed));
                     Payload_Alignment :=
                       Landin.Targets.Byte_Alignment'Max
                         (Payload_Alignment,
                          Landin.Targets.Alignment_Of (Placed));
                  end;
               end loop;

               Landin.Targets.Place (Part, Tag_Size, Facts, Ignored);
               if not Landin.Targets.Can_Place
                 (Part, Payload_Size, Payload_Alignment,
                  Landin.Targets.Maximum_Object_Size (Facts))
               then
                  Layout_Possible := False;
                  Size := 0;
                  Alignment := 1;
                  return;
               end if;
               Landin.Targets.Place
                 (Part, Payload_Size, Payload_Alignment, Ignored);
               Size := Landin.Targets.Size_Of (Part);
               Alignment := Landin.Targets.Alignment_Of (Part);

               pragma Assert (Size >= Tag_Bytes);
            end;
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
            if not Layout_Possible then
               Fits := False;
               return;
            end if;
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

      --  Payload shapes and their case runs precede the containing
      --  struct's top-level field run.  Rebase the source-local indexes
      --  while retaining the same target-neutral shape.
      declare
         Payload_Base : constant Natural :=
           Natural (Into.Field_Shapes.Length);
         Case_Base : constant Natural := Natural (Into.Case_Runs.Length);
      begin
         for Payload of Payloads loop
            Into.Field_Shapes.Append (Payload);
         end loop;

         for Run of Cases loop
            Into.Case_Runs.Append
              (Case_Run'(First =>
                  (if Run.Count = 0 then 0 else Payload_Base + Run.First),
                Count => Run.Count));
         end loop;

         Built.First := Natural (Into.Field_Offsets.Length) + 1;
         Built.Shape_First := Natural (Into.Field_Shapes.Length) + 1;
         Built.Count := Fields'Length;
         Built.Placed := Landin.Targets.Empty_Placement;

         for Field in Fields'Range loop
            declare
               Size      : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
               At_Offset : Landin.Targets.Byte_Count;
               Stored    : Field_Shape := Fields (Field);
            begin
               Extent_Of (Fields (Field), Size, Alignment);
               if not Layout_Possible then
                  Fits := False;
                  return;
               end if;
               Landin.Targets.Place
                 (Built.Placed, Size, Alignment, At_Offset);
               Into.Field_Offsets.Append (At_Offset);
               if Stored.Kind = Variant_Field then
                  Stored.Payloads_First :=
                    Case_Base + Stored.Payloads_First;
               end if;
               Into.Field_Shapes.Append (Stored);
            end;
         end loop;
      end;

      Built.Ready := True;
      Into.Layouts (Natural (Id)) := Built;
      Fits := True;
   end Lay_Out;

   function Has_Variant_Part (Of_Table : Table; Id : Declaration_Id)
     return Boolean
   is
   begin
      for Field in 1 .. Layout_Field_Count (Of_Table, Id) loop
         if Field_Kind_Of (Of_Table, Id, Field) = Variant_Field then
            return True;
         end if;
      end loop;
      return False;
   end Has_Variant_Part;

   function Has_Aggregate_Field (Of_Table : Table; Id : Declaration_Id)
     return Boolean
   is
   begin
      for Field in 1 .. Layout_Field_Count (Of_Table, Id) loop
         if Field_Kind_Of (Of_Table, Id, Field) = Aggregate_Field then
            return True;
         end if;
      end loop;
      return False;
   end Has_Aggregate_Field;

   function Field_Shape_Of
     (Of_Table : Table; Id : Declaration_Id; Field : Positive)
      return Field_Shape
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes (Layout.Shape_First + Field - 1);
   end Field_Shape_Of;

   function Variant_Case_Field_Count
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive;
      Which    : Positive) return Natural
   is
      Shape : constant Field_Shape := Field_Shape_Of
        (Of_Table, Id, Field);
   begin
      return Of_Table.Case_Runs
        (Shape.Payloads_First + Which - 1).Count;
   end Variant_Case_Field_Count;

   function Nth_Variant_Case_Field
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive;
      Which    : Positive;
      Payload_Field : Positive) return Field_Shape
   is
      Shape : constant Field_Shape := Field_Shape_Of
        (Of_Table, Id, Field);
      Run : constant Case_Run := Of_Table.Case_Runs
        (Shape.Payloads_First + Which - 1);
   begin
      return Of_Table.Field_Shapes (Run.First + Payload_Field - 1);
   end Nth_Variant_Case_Field;

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
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Element;
   end Field_Type;

   function Field_Kind_Of
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Field_Kind
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Kind;
   end Field_Kind_Of;

   function Field_Array_Length
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Element_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Length;
   end Field_Array_Length;

   function Field_Array_Element
     (Of_Table : Table;
      Id       : Declaration_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Natural (Body_Of (Of_Table, Id)));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Element;
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
