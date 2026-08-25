package body Landin.Checking is

   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;

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
            end loop;
         end;
      end loop;

      for Unused in 1 .. Landin.Resolution.Declaration_Count (Meanings) loop
         Into.Declarations.Append (Settlement'(others => <>));
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
