package body Landin.Checking is

   package body Nominal_Identities is
      function None return Id is (0);


      function From_Position (Position : Positive) return Id
        is (Id (Position));

      function Position (Of_Id : Id) return Natural is (Natural (Of_Id));
   end Nominal_Identities;

   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Syntax.Node_Kind;
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
               Into.Node_Nominals.Append (No_Nominal_Type);
               Into.Node_Atom_Sets.Append (No_Atom_Set);
               Into.Node_Signatures.Append (No_Signature);
               Into.Node_Result_Shapes.Append (No_Signature);
               Into.Node_Fields.Append (0);
               Into.Node_Shapes.Append (Array_Shape'(others => <>));
            end loop;
         end;
      end loop;

      for Unused in 1 .. Landin.Resolution.Declaration_Count (Meanings) loop
         Into.Declarations.Append (Settlement'(others => <>));
         Into.Declaration_Nominals.Append (No_Nominal_Type);
         Into.Empty_Nominals.Append (No_Nominal_Type);
         Into.Shapes.Append (Array_Shape'(others => <>));
         Into.Declaration_Atom_Sets.Append (No_Atom_Set);
         Into.Declaration_Signatures.Append (No_Signature);
         Into.Declaration_Result_Shapes.Append (No_Signature);
      end loop;

      --  Allocate every enabled empty-actual nominal instance in source
      --  declaration order before checking can follow a forward reference.
      --  Thus identity is target-independent and independent of traversal.
      for Id in Landin.Provenance.Declaration_Id'(1)
                .. Landin.Provenance.Declaration_Id
                     (Landin.Resolution.Declaration_Count (Meanings))
      loop
         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees, Landin.Resolution.Source_Of (Meanings, Id));
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Resolution.Node_Of (Meanings, Id);
            Written : constant Landin.Syntax.Node_Id :=
              (if Landin.Syntax.Kind (Of_Tree.all, Node)
                    = Landin.Syntax.Type_Declaration
               then Landin.Syntax.Declared_Type (Of_Tree.all, Node)
               else Landin.Syntax.No_Node);
         begin
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Type_Declaration
              and then Landin.Syntax.Type_Formal_Count (Of_Tree.all, Node) = 0
              and then Written /= Landin.Syntax.No_Node
              and then Landin.Syntax.Kind (Of_Tree.all, Written)
                           = Landin.Syntax.Struct_Body
            then
               Into.Nominal_Templates.Append (Id);
               Into.Layouts.Append (Aggregate_Layout'(others => <>));
               declare
                  Made : constant Nominal_Type_Id :=
                    Nominal_Identities.From_Position
                      (Into.Nominal_Templates.Last_Index);
               begin
                  Into.Empty_Nominals (Positive (Id)) := Made;
                  Into.Declaration_Nominals (Positive (Id)) := Made;
               end;
            end if;
         end;
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

   function Nominal_Type_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Nominal_Templates.Length));

   function Nth_Nominal_Type
     (Of_Table : Table; Position : Positive) return Nominal_Type_Id
   is
      pragma Unreferenced (Of_Table);
   begin
      return Nominal_Identities.From_Position (Position);
   end Nth_Nominal_Type;

   function Holds (Of_Table : Table; Id : Nominal_Type_Id) return Boolean
     is (Of_Table.Ready
         and then Id /= No_Nominal_Type
         and then Nominal_Identities.Position (Id)
                    <= Nominal_Type_Count (Of_Table));

   function Template_Of
     (Of_Table : Table; Id : Nominal_Type_Id) return Declaration_Id
     is (Of_Table.Nominal_Templates
           (Positive (Nominal_Identities.Position (Id))));

   function Empty_Nominal_Instance
     (Of_Table : Table; Template : Declaration_Id) return Nominal_Type_Id
     is (if Template = No_Declaration then No_Nominal_Type
         else Of_Table.Empty_Nominals (Positive (Template)));

   function Nominal_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Nominal_Type_Id
     is (Of_Table.Node_Nominals (Slot (Of_Table, Of_Tree, Node)));

   function Nominal_Of
     (Of_Table : Table; Id : Declaration_Id) return Nominal_Type_Id
     is (if Id = No_Declaration then No_Nominal_Type
         else Of_Table.Declaration_Nominals (Positive (Id)));

   procedure Note_Nominal
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Nominal : Nominal_Type_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Node_Nominals (Where) /= No_Nominal_Type
        and then Into.Node_Nominals (Where) /= Nominal
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two nominal type identities";
      end if;

      Into.Node_Nominals (Where) := Nominal;
   end Note_Nominal;

   procedure Note_Nominal
     (Into   : in out Table;
      Id     : Declaration_Id;
      Nominal : Nominal_Type_Id) is
   begin
      if Into.Declaration_Nominals (Positive (Id)) /= No_Nominal_Type
        and then Into.Declaration_Nominals (Positive (Id)) /= Nominal
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two nominal type identities";
      end if;

      Into.Declaration_Nominals (Positive (Id)) := Nominal;
   end Note_Nominal;

   ------------------------------------------------------------------
   --  Atom sets
   ------------------------------------------------------------------

   function Atom_Set_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Atom_Sets.Length));

   function Add_Atom_Set
     (Into : in out Table; Atoms : Atom_Array) return Atom_Set_Id
   is
      Made : Atom_Set_Record := (Members => (First => 0, Count => 0));
   begin
      Made.Members.First := Natural (Into.Atoms.Length);
      for Atom of Atoms loop
         Into.Atoms.Append (Atom);
         Made.Members.Count := Made.Members.Count + 1;
      end loop;
      Into.Atom_Sets.Append (Made);
      return Atom_Set_Id (Into.Atom_Sets.Last_Index);
   end Add_Atom_Set;

   function Atom_Count
     (Of_Table : Table; Set_Id : Atom_Set_Id) return Natural
     is (Of_Table.Atom_Sets (Positive (Set_Id)).Members.Count);

   function Nth_Atom
     (Of_Table : Table; Set_Id : Atom_Set_Id; Index : Positive)
      return Declaration_Id
   is
      Members : constant Run :=
        Of_Table.Atom_Sets (Positive (Set_Id)).Members;
   begin
      return Of_Table.Atoms (Members.First + Index);
   end Nth_Atom;

   function Contains_Atom
     (Of_Table : Table; Set_Id : Atom_Set_Id; Atom : Declaration_Id)
      return Boolean
   is
   begin
      for Index in 1 .. Atom_Count (Of_Table, Set_Id) loop
         if Nth_Atom (Of_Table, Set_Id, Index) = Atom then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Atom;

   function Is_Subset
     (Of_Table : Table; Left, Right : Atom_Set_Id) return Boolean
   is
   begin
      for Index in 1 .. Atom_Count (Of_Table, Left) loop
         if not Contains_Atom
           (Of_Table, Right, Nth_Atom (Of_Table, Left, Index))
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_Subset;

   function Atom_Sets_Agree
     (Of_Table : Table; Left, Right : Atom_Set_Id) return Boolean
     is (Atom_Count (Of_Table, Left) = Atom_Count (Of_Table, Right)
         and then Is_Subset (Of_Table, Left, Right));

   function Atom_Set_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Atom_Set_Id
     is (Of_Table.Node_Atom_Sets (Slot (Of_Table, Of_Tree, Node)));

   function Atom_Set_Of
     (Of_Table : Table; Id : Declaration_Id) return Atom_Set_Id
     is (if Id = No_Declaration then No_Atom_Set
         else Of_Table.Declaration_Atom_Sets (Positive (Id)));

   procedure Note_Atom_Set
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Set_Id  : Atom_Set_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Node_Atom_Sets (Where) /= No_Atom_Set
        and then not Atom_Sets_Agree
          (Into, Into.Node_Atom_Sets (Where), Set_Id)
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two atom sets";
      end if;
      Into.Node_Atom_Sets (Where) := Set_Id;
   end Note_Atom_Set;

   procedure Note_Atom_Set
     (Into   : in out Table;
      Id     : Declaration_Id;
      Set_Id : Atom_Set_Id) is
   begin
      if Into.Declaration_Atom_Sets (Positive (Id)) /= No_Atom_Set
        and then not Atom_Sets_Agree
          (Into, Into.Declaration_Atom_Sets (Positive (Id)), Set_Id)
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two atom sets";
      end if;
      Into.Declaration_Atom_Sets (Positive (Id)) := Set_Id;
   end Note_Atom_Set;

   ------------------------------------------------------------------
   --  Function signatures
   ------------------------------------------------------------------

   function Signature_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Signatures.Length));

   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Results    : Signature_Part_Array;
      Site       : Landin.Provenance.Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible) return Signature_Id
   is
      Made : Signature_Record :=
        (Parameters => (First => 0, Count => 0),
         Results    => (First => 0, Count => 0),
         Site       => Site,
         Errors     => Errors,
         Error_Form => Error_Form);

      procedure Append
        (Parts : Signature_Part_Array; To_Run : in out Run);

      procedure Append
        (Parts : Signature_Part_Array; To_Run : in out Run) is
      begin
         if Parts'Length > 0 then
            To_Run.First := Natural (Into.Signature_Parts.Length);
            for Part of Parts loop
               Into.Signature_Parts.Append (Part);
               To_Run.Count := To_Run.Count + 1;
            end loop;
         end if;
      end Append;
   begin
      Append (Parameters, Made.Parameters);
      Append (Results, Made.Results);
      Into.Signatures.Append (Made);
      return Signature_Id (Into.Signatures.Last_Index);
   end Add_Signature;

   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Result     : Signature_Part;
      Site       : Landin.Provenance.Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible) return Signature_Id
   is
   begin
      if Result.Kind = Landin.Types.No_Value then
         return Add_Signature
           (Into, Parameters, No_Signature_Parts, Site,
            Errors, Error_Form);
      end if;
      return Add_Signature
        (Into, Parameters, Signature_Part_Array'[1 => Result], Site,
         Errors, Error_Form);
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

   function Signature_Result_Count
     (Of_Table : Table; Signature : Signature_Id) return Natural
     is (Of_Table.Signatures (Positive (Signature)).Results.Count);

   function Nth_Signature_Result
     (Of_Table : Table; Signature : Signature_Id; Index : Positive)
      return Signature_Part
   is
      Results : constant Run :=
        Of_Table.Signatures (Positive (Signature)).Results;
   begin
      return Of_Table.Signature_Parts (Results.First + Index);
   end Nth_Signature_Result;

   function Signature_Result
     (Of_Table : Table; Signature : Signature_Id) return Signature_Part
   is
   begin
      if Signature_Result_Count (Of_Table, Signature) = 0 then
         return
           (Kind => Landin.Types.No_Value,
            Site => Signature_Origin (Of_Table, Signature),
            others => <>);
      end if;
      return Nth_Signature_Result (Of_Table, Signature, 1);
   end Signature_Result;

   function Signature_Origin
     (Of_Table : Table; Signature : Signature_Id)
      return Landin.Provenance.Origin
     is (Of_Table.Signatures (Positive (Signature)).Site);

   function Signature_Error_Form
     (Of_Table : Table; Signature : Signature_Id) return Error_Set_Form
     is (Of_Table.Signatures (Positive (Signature)).Error_Form);

   function Signature_Errors
     (Of_Table : Table; Signature : Signature_Id) return Atom_Set_Id
     is (Of_Table.Signatures (Positive (Signature)).Errors);

   procedure Finalize_Inferred_Errors
     (Into      : in out Table;
      Signature : Signature_Id;
      Errors    : Atom_Set_Id)
   is
      Held : Signature_Record := Into.Signatures (Positive (Signature));
   begin
      Held.Errors := Errors;
      Held.Error_Form := (if Errors = No_Atom_Set then Infallible
                          else Concrete);
      Into.Signatures (Positive (Signature)) := Held;
   end Finalize_Inferred_Errors;

   function Parts_Agree
     (Of_Table : Table; A, B : Signature_Part) return Boolean;

   function Parts_Agree
     (Of_Table : Table; A, B : Signature_Part) return Boolean
   is
   begin
      if A.Kind /= B.Kind then
         return False;
      end if;
      case A.Kind is
         when Landin.Types.No_Value =>
            return True;
         when Landin.Types.Scalar_Name =>
            return True;
         when Landin.Types.Atom_Value =>
            return Holds (Of_Table, A.Atoms)
              and then Holds (Of_Table, B.Atoms)
              and then Atom_Sets_Agree (Of_Table, A.Atoms, B.Atoms);
         when Landin.Types.Aggregate =>
            return A.Nominal = B.Nominal;
         when Landin.Types.Fixed_Array =>
            return A.Length = B.Length
              and then A.Element = B.Element
              and then A.Nominal = B.Nominal;
         when Landin.Types.Function_Value =>
            return Holds (Of_Table, A.Signature)
              and then Holds (Of_Table, B.Signature)
              and then Signatures_Agree
                (Of_Table, A.Signature, B.Signature);
         when others =>
            return False;
      end case;
   end Parts_Agree;

   function Signatures_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
   is
   begin
      if Left = Right then
         return True;
      end if;

      if Signature_Error_Form (Of_Table, Left) = Inferred
        or else Signature_Error_Form (Of_Table, Right) = Inferred
        or else Signature_Error_Form (Of_Table, Left)
                  /= Signature_Error_Form (Of_Table, Right)
        or else
          (Signature_Error_Form (Of_Table, Left) = Concrete
           and then not Atom_Sets_Agree
             (Of_Table, Signature_Errors (Of_Table, Left),
              Signature_Errors (Of_Table, Right)))
        or else Signature_Parameter_Count (Of_Table, Left)
           /= Signature_Parameter_Count (Of_Table, Right)
        or else Signature_Result_Count (Of_Table, Left)
           /= Signature_Result_Count (Of_Table, Right)
      then
         return False;
      end if;

      for Index in 1 .. Signature_Parameter_Count (Of_Table, Left) loop
         if not Parts_Agree
           (Of_Table,
            Nth_Signature_Parameter (Of_Table, Left, Index),
            Nth_Signature_Parameter (Of_Table, Right, Index))
         then
            return False;
         end if;
      end loop;

      for Index in 1 .. Signature_Result_Count (Of_Table, Left) loop
         if not Parts_Agree
           (Of_Table,
            Nth_Signature_Result (Of_Table, Left, Index),
            Nth_Signature_Result (Of_Table, Right, Index))
         then
            return False;
         end if;
      end loop;
      return True;
   end Signatures_Agree;

   function Result_Shape_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Signature_Id
     is (Of_Table.Node_Result_Shapes (Slot (Of_Table, Of_Tree, Node)));

   function Result_Shape_Of
     (Of_Table : Table; Id : Declaration_Id) return Signature_Id
     is (if Id = No_Declaration then No_Signature
         else Of_Table.Declaration_Result_Shapes (Positive (Id)));

   procedure Note_Result_Shape
     (Into      : in out Table;
      Of_Tree   : Landin.Syntax.Tree;
      Node      : Landin.Syntax.Node_Id;
      Signature : Signature_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Node_Result_Shapes (Where) /= No_Signature
        and then Into.Node_Result_Shapes (Where) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two anonymous result shapes";
      end if;
      Into.Node_Result_Shapes (Where) := Signature;
   end Note_Result_Shape;

   procedure Note_Result_Shape
     (Into      : in out Table;
      Id        : Declaration_Id;
      Signature : Signature_Id) is
   begin
      if Into.Declaration_Result_Shapes (Positive (Id)) /= No_Signature
        and then Into.Declaration_Result_Shapes (Positive (Id)) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two anonymous result shapes";
      end if;
      Into.Declaration_Result_Shapes (Positive (Id)) := Signature;
   end Note_Result_Shape;

   function Result_Shapes_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
   is
   begin
      if Signature_Result_Count (Of_Table, Left)
           /= Signature_Result_Count (Of_Table, Right)
      then
         return False;
      end if;
      for Index in 1 .. Signature_Result_Count (Of_Table, Left) loop
         declare
            A : constant Signature_Part :=
              Nth_Signature_Result (Of_Table, Left, Index);
            B : constant Signature_Part :=
              Nth_Signature_Result (Of_Table, Right, Index);
         begin
            if A.Name /= B.Name or else not Parts_Agree (Of_Table, A, B) then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Result_Shapes_Agree;

   ------------------------------------------------------------------
   --  How an aggregate is laid out
   ------------------------------------------------------------------

   function Has_Layout (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
     is (Id /= No_Nominal_Type
         and then Of_Table.Layouts (Nominal_Identities.Position (Id)).Ready);

   function Layout_Field_Count (Of_Table : Table; Id : Nominal_Type_Id)
     return Natural
     is (Of_Table.Layouts
           (Nominal_Identities.Position (Id)).Count);

   procedure Lay_Out
     (Into  : in out Table;
      Id    : Nominal_Type_Id;
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
            if Field.Nominal /= No_Nominal_Type then
               if not Holds (Into, Field.Nominal)
                 or else not Has_Layout (Into, Field.Nominal)
               then
                  raise Landin.Compiler_Defect with
                    "an aggregate array element has no laid-out body";
               end if;
               Array_Extent
                 (Into, Field.Length, Field.Nominal, Size, Alignment);
            else
               Array_Extent
                 (Field.Length, Field.Element, Facts, Size, Alignment);
            end if;
         elsif Field.Kind = Aggregate_Field then
            if Field.Nominal = No_Nominal_Type
              or else not Holds (Into, Field.Nominal)
              or else not Has_Layout (Into, Field.Nominal)
            then
               raise Landin.Compiler_Defect with
                 "an aggregate field has no laid-out body";
            end if;
            Size := Layout_Size (Into, Field.Nominal);
            Alignment := Layout_Alignment (Into, Field.Nominal);
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
      Into.Layouts (Nominal_Identities.Position (Id)) := Built;
      Fits := True;
   end Lay_Out;

   function Has_Variant_Part (Of_Table : Table; Id : Nominal_Type_Id)
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

   function Has_Aggregate_Field (Of_Table : Table; Id : Nominal_Type_Id)
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
     (Of_Table : Table; Id : Nominal_Type_Id; Field : Positive)
      return Field_Shape
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Id));
   begin
      return Of_Table.Field_Shapes (Layout.Shape_First + Field - 1);
   end Field_Shape_Of;

   function Variant_Case_Field_Count
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
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
      Id       : Nominal_Type_Id;
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
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Targets.Byte_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Id));
   begin
      return Of_Table.Field_Offsets (Layout.First + Field - 1);
   end Field_Offset;

   function Field_Type
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Element;
   end Field_Type;

   function Field_Kind_Of
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Field_Kind
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Kind;
   end Field_Kind_Of;

   function Field_Array_Length
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Element_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Length;
   end Field_Array_Length;

   function Field_Array_Element
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Element;
   end Field_Array_Element;

   function Layout_Extent (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Count
     is (Landin.Targets.Extent_Of
           (Of_Table.Layouts
              (Nominal_Identities.Position (Id)).Placed));

   function Layout_Alignment (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Alignment
     is (Landin.Targets.Alignment_Of
           (Of_Table.Layouts
              (Nominal_Identities.Position (Id)).Placed));

   function Layout_Size (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Count
     is (Landin.Targets.Size_Of
           (Of_Table.Layouts
              (Nominal_Identities.Position (Id)).Placed));

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
        Array_Shape'(Length => Length, Element => Element, others => <>);
   end Note_Array;

   function Array_Element_Nominal
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Nominal_Type_Id
     is (Of_Table.Node_Shapes
           (Slot (Of_Table, Of_Tree, Node)).Element_Nominal);

   procedure Note_Array_Element_Nominal
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Nominal : Nominal_Type_Id) is
   begin
      Into.Node_Shapes (Slot (Into, Of_Tree, Node)).Element_Nominal := Nominal;
   end Note_Array_Element_Nominal;

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
        Array_Shape'(Length => Length, Element => Element, others => <>);
   end Note_Array;

   function Array_Element_Nominal
     (Of_Table : Table; Id : Declaration_Id) return Nominal_Type_Id
     is (Of_Table.Shapes (Natural (Id)).Element_Nominal);

   procedure Note_Array_Element_Nominal
     (Into  : in out Table;
      Id      : Declaration_Id;
      Nominal : Nominal_Type_Id) is
   begin
      Into.Shapes (Natural (Id)).Element_Nominal := Nominal;
   end Note_Array_Element_Nominal;

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

   procedure Array_Extent
     (Of_Table  : Table;
      Length    : Element_Count;
      Element   : Nominal_Type_Id;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Held : constant Landin.Targets.Byte_Count :=
        Layout_Size (Of_Table, Element);
   begin
      Alignment :=
        (if Length = 0 then 1
         else Layout_Alignment (Of_Table, Element));
      Size := Landin.Targets.Byte_Count (Length) * Held;
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
