package body Landin.Resolution is

   ------------------------------------------------------------------
   --  Sizing
   ------------------------------------------------------------------

   function Is_Prepared (Of_Table : Table) return Boolean
     is (Of_Table.Ready);

   function Source_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Runs.Length));

   function Node_Limit
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     is (if Id = Landin.Source.No_Source
           or else Natural (Id) > Source_Count (Of_Table)
         then 0
         else Of_Table.Runs.Element (Positive (Id)).Count);

   function Covers (Of_Table : Table; Of_Tree : Landin.Syntax.Tree)
     return Boolean
     is (Node_Limit (Of_Table, Landin.Syntax.Source_Of (Of_Tree))
         = Landin.Syntax.Node_Count (Of_Tree));

   procedure Prepare
     (Into : in out Table; Trees : Landin.Syntax.Forest.Table)
   is
      Next : Natural := 0;
   begin
      for Index in 1 .. Landin.Syntax.Forest.Count (Trees) loop
         declare
            Id : constant Landin.Source.Source_Id :=
              Landin.Source.Source_Id (Index);
            Size : constant Natural :=
              Landin.Syntax.Node_Count
                (Landin.Syntax.Forest.Tree_Of (Trees, Id).all);
         begin
            Into.Runs.Append (Run'(First => Next + 1, Count => Size));
            Next := Next + Size;
         end;
      end loop;

      --  One slot per node of every tree, all No_Declaration.  Nothing is
      --  a reference until something says so, which is the third answer
      --  Verdict already gives without storing it.
      Into.Bound.Append (No_Declaration, Ada.Containers.Count_Type (Next));
      Into.Opened.Append (No_Scope, Ada.Containers.Count_Type (Next));
      Into.Applications.Append
        (Application_Fact'(others => <>),
         Ada.Containers.Count_Type (Next));

      --  [1740] gives the compilation one scope and this is it.
      Into.Scopes.Append (Scope'(Sort => Program, Enclosing => No_Scope));
      Into.Ready := True;
   end Prepare;

   ------------------------------------------------------------------
   --  Scopes
   ------------------------------------------------------------------

   function Scope_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Scopes.Length));

   function Sort_Of (Of_Table : Table; Scope : Scope_Id) return Scope_Sort
     is (Of_Table.Scopes.Element (Positive (Scope)).Sort);

   function Enclosing (Of_Table : Table; Scope : Scope_Id) return Scope_Id
     is (Of_Table.Scopes.Element (Positive (Scope)).Enclosing);

   function Open_Scope
     (Into : in out Table; Sort : Scope_Sort; Inside : Scope_Id)
     return Scope_Id
   is
   begin
      Into.Scopes.Append (Scope'(Sort => Sort, Enclosing => Inside));
      return Scope_Id (Into.Scopes.Length);
   end Open_Scope;

   ------------------------------------------------------------------
   --  Declarations
   ------------------------------------------------------------------

   function Hash (Item : Key) return Ada.Containers.Hash_Type is
      use type Ada.Containers.Hash_Type;
   begin
      return Ada.Containers.Hash_Type (Item.Scope) * 31
             + Landin.Source.Names.Hash (Item.Name);
   end Hash;

   function Declaration_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Declarations.Length));

   function Element (Of_Table : Table; Id : Declaration_Id)
     return Declaration
     is (Of_Table.Declarations.Element (Positive (Id)));

   function Name_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Source.Names.Name_Id
     is (Element (Of_Table, Id).Name);

   function Sort_Of (Of_Table : Table; Id : Declaration_Id)
     return Declaration_Sort
     is (Element (Of_Table, Id).Sort);

   function Scope_Of (Of_Table : Table; Id : Declaration_Id)
     return Scope_Id
     is (Element (Of_Table, Id).Scope);

   function Source_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Source.Source_Id
     is (Element (Of_Table, Id).Source);

   function Node_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Syntax.Node_Id
     is (Element (Of_Table, Id).Node);

   function Is_Public (Of_Table : Table; Id : Declaration_Id)
     return Boolean
     is (Element (Of_Table, Id).Public);

   function Declared_Here
     (Of_Table : Table;
      Scope    : Scope_Id;
      Name     : Landin.Source.Names.Name_Id) return Declaration_Id
   is
      Found : constant Key_Maps.Cursor :=
        Of_Table.Index.Find (Key'(Scope => Scope, Name => Name));
   begin
      return (if Key_Maps.Has_Element (Found)
              then Key_Maps.Element (Found)
              else No_Declaration);
   end Declared_Here;

   function Visible
     (Of_Table : Table;
      Scope    : Scope_Id;
      Name     : Landin.Source.Names.Name_Id) return Declaration_Id
   is
      Where : Scope_Id := Scope;
   begin
      --  Outward, one scope at a time, and the first answer wins.  That is
      --  [0140]: an inner scope may shadow an outer name.
      while Where /= No_Scope loop
         declare
            Found : constant Declaration_Id :=
              Declared_Here (Of_Table, Where, Name);
         begin
            if Found /= No_Declaration then
               return Found;
            end if;
         end;

         Where := Enclosing (Of_Table, Where);
      end loop;

      return No_Declaration;
   end Visible;

   --  What a declaration declares, from the node and the scope it is in.
   --  [1790]'s binding is one rule that [1740] and [1810] both use, and
   --  the scope is the whole difference.
   function Sorted
     (Of_Kind : Landin.Syntax.Node_Kind; Inside : Scope_Sort)
     return Declaration_Sort
     is (case Of_Kind is
            when Landin.Syntax.Function_Declaration => Module_Function,
            when Landin.Syntax.Atom_Declaration     => Module_Atom,
            --  [1795]: a type declaration names a type, and the kernel
            --  has only the module scope to name one in.
            when Landin.Syntax.Type_Declaration     => Module_Type,
            when Landin.Syntax.Type_Formal           => Type_Parameter,
            when Landin.Syntax.Fixed_Formal          => Fixed_Parameter,
            when Landin.Syntax.Variant_Case         => Case_Name,
            when Landin.Syntax.Match_Binding        => Pattern_Binding,
            when Landin.Syntax.Destructured_Name    => Result_Binding,
            when Landin.Syntax.Recovery_Clause       => Error_Binding,
            when Landin.Syntax.Parameter            => Parameter,
            when Landin.Syntax.Named_Return         => Named_Return,
            when Landin.Syntax.Binding              =>
               (if Inside = Program then Module_Binding else Local_Binding),
            when others                             => Local_Binding);

   function Declare_Name
     (Into    : in out Table;
      Sites   : in out Landin.Provenance.Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Inside  : Scope_Id) return Declaration_Id
   is
      Kind : constant Landin.Syntax.Node_Kind :=
        Landin.Syntax.Kind (Of_Tree, Node);

      Named : constant Landin.Source.Names.Name_Id :=
        Landin.Syntax.Name (Of_Tree, Node);

      --  The anchor and not the extent: Landin.Syntax promises that a
      --  declaration's anchor is where its name is written, which is the
      --  span a duplicate report and R4.60 both point at.
      Site : constant Landin.Provenance.Origin :=
        (Source => Landin.Syntax.Source_Of (Of_Tree),
         Where  => Landin.Syntax.Anchor (Of_Tree, Node));

      Fresh : constant Declaration_Id :=
        Landin.Provenance.Record_Site (Sites, Site);
   begin
      --  The site table and this one are one numbering, so a declaration
      --  that is not the next number in both is a defect in the caller
      --  rather than a row nobody can look up.
      if Natural (Fresh) /= Declaration_Count (Into) + 1 then
         raise Compiler_Defect
           with "the declaration table and the site table disagree";
      end if;

      Into.Declarations.Append
        (Declaration'
           (Sort   => Sorted (Kind, Sort_Of (Into, Inside)),
            Name   => Named,
            Scope  => Inside,
            Source => Landin.Syntax.Source_Of (Of_Tree),
            Node   => Node,
            Public =>
              Kind in Landin.Syntax.Function_Declaration
                      | Landin.Syntax.Atom_Declaration
                      | Landin.Syntax.Binding
              and then Landin.Syntax.Is_Public (Of_Tree, Node)));

      Into.Index.Insert (Key'(Scope => Inside, Name => Named), Fresh);
      return Fresh;
   end Declare_Name;

   ------------------------------------------------------------------
   --  References
   ------------------------------------------------------------------

   function Slot
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Positive
     is (Of_Table.Runs.Element
           (Positive (Landin.Syntax.Source_Of (Of_Tree))).First
         + Natural (Node) - 1);

   function Verdict_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Verdict
     is (if Landin.Syntax.Kind (Of_Tree, Node)
            not in Landin.Syntax.Name_Reference
                   | Landin.Syntax.Type_Reference
         then Not_A_Reference
         elsif Of_Table.Bound.Element (Slot (Of_Table, Of_Tree, Node))
               = No_Declaration
         then Unresolved
         else Bound);

   function Bound_To
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Declaration_Id
     is (Of_Table.Bound.Element (Slot (Of_Table, Of_Tree, Node)));

   function Scope_At
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Scope_Id
     is (Of_Table.Opened.Element (Slot (Of_Table, Of_Tree, Node)));

   procedure Record_Scope
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Opened  : Scope_Id)
   is
   begin
      Into.Opened.Replace_Element (Slot (Into, Of_Tree, Node), Opened);
   end Record_Scope;

   procedure Bind
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      To      : Declaration_Id)
   is
   begin
      Into.Bound.Replace_Element (Slot (Into, Of_Tree, Node), To);
   end Bind;

   function Class_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Application_Class
     is (Of_Table.Applications.Element
           (Slot (Of_Table, Of_Tree, Node)).Class);

   function Match_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Call_Match_State
     is (Of_Table.Applications.Element
           (Slot (Of_Table, Of_Tree, Node)).Match);

   function Role_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id) return Argument_Role
     is (Of_Table.Applications.Element
           (Slot (Of_Table, Of_Tree, Argument)).Role);

   function Formal_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id) return Declaration_Id
     is (Of_Table.Applications.Element
           (Slot (Of_Table, Of_Tree, Argument)).Formal);

   function Position_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id) return Natural
     is (Of_Table.Applications.Element
           (Slot (Of_Table, Of_Tree, Argument)).Position);

   procedure Classify
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      As_Kind : Application_Class)
   is
      Slot_Index : constant Positive := Slot (Into, Of_Tree, Node);
      Fact : Application_Fact := Into.Applications.Element (Slot_Index);
   begin
      Fact.Class := As_Kind;
      Into.Applications.Replace_Element (Slot_Index, Fact);
   end Classify;

   procedure Match_Argument
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id;
      As_Role  : Argument_Role;
      Position : Natural;
      Formal   : Declaration_Id := No_Declaration)
   is
      Slot_Index : constant Positive := Slot (Into, Of_Tree, Argument);
      Fact : Application_Fact := Into.Applications.Element (Slot_Index);
   begin
      Fact.Role := As_Role;
      Fact.Formal := Formal;
      Fact.Position := Position;
      Into.Applications.Replace_Element (Slot_Index, Fact);
   end Match_Argument;

   procedure Match_Runtime_Argument
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Argument : Landin.Syntax.Node_Id;
      Position : Positive)
   is
      Slot_Index : constant Positive := Slot (Into, Of_Tree, Argument);
      Fact : Application_Fact := Into.Applications.Element (Slot_Index);
   begin
      if Fact.Role /= Runtime_Argument
        or else Fact.Position /= Position
      then
         Fact.Formal := No_Declaration;
      end if;
      Fact.Role := Runtime_Argument;
      Fact.Position := Position;
      Into.Applications.Replace_Element (Slot_Index, Fact);
   end Match_Runtime_Argument;

   procedure Finish_Call_Match
     (Into     : in out Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id;
      Accepted : Boolean)
   is
      Slot_Index : constant Positive := Slot (Into, Of_Tree, Node);
      Fact : Application_Fact := Into.Applications.Element (Slot_Index);
   begin
      Fact.Match := (if Accepted then Call_Matched else Call_Rejected);
      Into.Applications.Replace_Element (Slot_Index, Fact);
   end Finish_Call_Match;

end Landin.Resolution;
