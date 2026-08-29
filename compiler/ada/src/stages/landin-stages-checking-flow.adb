with Ada.Containers.Ordered_Sets;
with Ada.Strings.Fixed;

with Landin.Checking;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Syntax.Forest;
with Landin.Types;

package body Landin.Stages.Checking.Flow is

   package Bad renames Landin.Diagnostics.Checking;
   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Types.Type_Kind;
   use type Landin.Types.Magnitude;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Field_Kind;
   use type Res.Verdict;
   use type Res.Declaration_Sort;
   use type Landin.Source.Source_Id;

   procedure Check_Function
     (Context       : in out Compilation;
      Of_Tree       : Syn.Tree;
      Function_Node : Syn.Node_Id;
      Body_Node     : Syn.Node_Id;
      Result_Node   : Syn.Node_Id;
      Into          : in out Landin.Diagnostics.Diagnostic_List)
   is
      Spellings : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Trees     : constant not null access Syn.Forest.Table :=
        Landin.Stages.Trees (Context);
      Meanings  : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Types     : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);
      Found : Landin.Diagnostics.Diagnostic_List renames Into;

      function Tree_For (Id : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Syn.Forest.Tree_Of (Trees.all, Id));

      function Spelled (Of_Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Spellings.all, Of_Name));

      function Written (Value : Ty.Folded) return String
        is (Ada.Strings.Fixed.Trim
              (Ty.Folded'Image (Value), Ada.Strings.Both));

      function Field_Named
        (Wrote : Res.Declaration_Id; Index : Positive) return String;

      function Field_Named
        (Wrote : Res.Declaration_Id; Index : Positive) return String
      is
         Field_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Wrote));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Wrote);
         Declared : constant Syn.Node_Id :=
           Syn.Declared_Type (Field_Tree.all, Node);
      begin
         if Declared = Syn.No_Node
           or else Syn.Kind (Field_Tree.all, Declared) /= Syn.Struct_Body
           or else Index > Syn.Field_Count (Field_Tree.all, Declared)
         then
            return "";
         end if;

         return Spelled
                  (Syn.Name
                     (Field_Tree.all,
                      Syn.Nth_Field (Field_Tree.all, Declared, Index)));
      end Field_Named;

      function Is_Known_Index
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Known_Index
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is (Syn.Kind (Tree, Node) = Syn.Integer_Literal
          or else
            (Syn.Kind (Tree, Node) = Syn.Negation
             and then Syn.Kind (Tree, Syn.Operand_Of (Tree, Node))
                      = Syn.Integer_Literal));

      function Known_Index_Value
        (Tree  : Syn.Tree;
         Node  : Syn.Node_Id;
         Value : out Ty.Magnitude) return Boolean;

      function Known_Index_Value
        (Tree  : Syn.Tree;
         Node  : Syn.Node_Id;
         Value : out Ty.Magnitude) return Boolean
      is
         Negated : constant Boolean := Syn.Kind (Tree, Node) = Syn.Negation;
         Literal : constant Syn.Node_Id :=
           (if Negated then Syn.Operand_Of (Tree, Node) else Node);
         Snap : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Tree));
         Overflowed : Boolean;
      begin
         if not Is_Known_Index (Tree, Node) then
            Value := 0;
            return False;
         end if;

         Ty.Evaluate
           (Landin.Source.Slice (Snap, Syn.Digit_Span (Tree, Literal)),
            Syn.Base (Tree, Literal), Value, Overflowed);
         return not Overflowed and then (not Negated or else Value = 0);
      end Known_Index_Value;

      --  [1910]: assigned before it is read
      ------------------------------------------------------------

      --  The widest struct the program writes, which is how many field
      --  bits a row of the set below needs.  Read from the trees rather
      --  than from the layouts, because this sizes a type and so is
      --  elaborated before the pass that lays anything out; a struct body
      --  is [0750]'s field list either way.
      function Widest_Struct return Natural;

      function Widest_Struct return Natural is
         Most : Natural := 0;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Nth_Source (Context, Index));
            begin
               for Node in Syn.Node_Id'(1)
                           .. Syn.Node_Id (Syn.Node_Count (Of_Tree.all))
               loop
                  if Syn.Kind (Of_Tree.all, Node) = Syn.Struct_Body then
                     Most :=
                       Natural'Max
                         (Most, Syn.Field_Count (Of_Tree.all, Node));
                  end if;
               end loop;
            end;
         end loop;

         return Most;
      end Widest_Struct;

      --  One Boolean per declaration, copied at a branch and merged after
      --  it.  A set and not a counter, because [1910] is about paths: a
      --  name assigned in one arm and not another is not assigned after
      --  the branch, and nothing but the per-declaration answer says that.
      --
      --  D16 makes a field of a struct local its own answer, so a row is
      --  the name at column zero and its fields at the columns after it.
      --  A scalar uses column zero alone; a struct never uses it, because
      --  a value of one is not a thing this kernel can read. D88's nested
      --  leaves use the sparse parent/child set below rather than flattening
      --  the nominal child into this top-level row.
      subtype Tracked is Positive range
        1 .. Positive'Max (1, Res.Declaration_Count (Meanings.all));

      subtype Tracked_Field is Natural range 0 .. Widest_Struct;

      Array_Path_Stride : constant Natural := Widest_Struct + 1;

      function Nested_Array_Path
        (Parent, Child : Tracked_Field) return Natural
      is (Natural (Parent) * Array_Path_Stride + Natural (Child));

      function Is_Nested_Array_Path (Path : Natural) return Boolean
      is (Path > Widest_Struct);

      function Array_Parent (Path : Natural) return Tracked_Field
      is (Tracked_Field (Path / Array_Path_Stride));

      function Array_Child (Path : Natural) return Tracked_Field
      is (Tracked_Field (Path mod Array_Path_Stride));

      type Assigned_Fields is array (Tracked, Tracked_Field) of Boolean;

      type Element_Fact is record
         Declaration : Res.Declaration_Id;
         Field       : Natural;
         Position    : Ty.Magnitude;
      end record;

      function "<" (Left, Right : Element_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then
               (Left.Field < Right.Field
                or else
                  (Left.Field = Right.Field
                   and then Left.Position < Right.Position))));

      package Element_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Element_Fact);

      type Array_Fact is record
         Declaration : Res.Declaration_Id;
         Field       : Natural;
      end record;

      function "<" (Left, Right : Array_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then Left.Field < Right.Field));

      package Array_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Array_Fact);

      type Nested_Fact is record
         Declaration : Res.Declaration_Id;
         Parent_Field : Tracked_Field;
         Child_Field  : Tracked_Field;
      end record;

      function "<" (Left, Right : Nested_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then
               (Left.Parent_Field < Right.Parent_Field
                or else
                  (Left.Parent_Field = Right.Parent_Field
                   and then Left.Child_Field < Right.Child_Field))));

      package Nested_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Nested_Fact);

      type Assigned_Set is record
         Fields       : Assigned_Fields := [others => [others => False]];
         Elements     : Element_Sets.Set;
         Whole_Arrays : Array_Sets.Set;
         Nested       : Nested_Sets.Set;
      end record;

      Nothing_Assigned : constant Assigned_Set :=
        (Fields       => [others => [others => False]],
         Elements     => Element_Sets.Empty_Set,
         Whole_Arrays => Array_Sets.Empty_Set,
         Nested       => Nested_Sets.Empty_Set);

      --  Which declarations [1910] is about.  A parameter arrives assigned
      --  and a module binding is [1940]'s, so what is left is a local
      --  declared with no value and the named return.
      function Is_Tracked (Id : Res.Declaration_Id) return Boolean;
      procedure Array_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Field   : out Natural);
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id;
      --  Whether the whole-array read is a D20 assignment source or a D21
      --  binding initializer.  Only Require_Array threads through, since
      --  every other whole-name read (a discard, an `inc`) is neither.
      type Whole_Array_Read is (Assignment_Source, Initializer_Source);
      procedure Read_Names
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         State    : Assigned_Set;
         Whole_As : Whole_Array_Read := Assignment_Source);
      procedure Flow_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         Owner   : Landin.Provenance.Origin;
         State   : in out Assigned_Set;
         Exits   : out Boolean);
      procedure Require_Assigned
        (At_Source : Landin.Source.Source_Id;
         At_Span   : Landin.Source.Span;
         Id        : Res.Declaration_Id;
         State     : Assigned_Set;
         Message   : String;
         Field     : Tracked_Field := 0);
      procedure Require_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         Field   : Natural;
         Position : Ty.Magnitude;
         State   : Assigned_Set);
      procedure Require_Computed_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         Field   : Natural;
         State   : Assigned_Set);
      function Array_Length_For
        (Id : Res.Declaration_Id; Field : Natural)
         return Landin.Checking.Element_Count;
      function Array_Label
        (Id : Res.Declaration_Id; Field : Natural) return String;
      function Array_Is_Assigned
        (Id    : Res.Declaration_Id;
         Field : Natural;
         State : Assigned_Set) return Boolean;
      procedure Require_Array
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         State    : Assigned_Set;
         Field    : Natural := 0;
         Whole_As : Whole_Array_Read := Assignment_Source);

      --  Which declaration a declaring node is.  Landin.Resolution
      --  publishes the other direction only, so this is a scan: over a
      --  list that is short, in the order the source decided, and asked
      --  once per function rather than once per node.
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Source_Of (Meanings.all, Id) = Src
              and then Res.Node_Of (Meanings.all, Id) = Node
            then
               return Id;
            end if;
         end loop;

         return Res.No_Declaration;
      end Declaration_At;

      function Is_Tracked (Id : Res.Declaration_Id) return Boolean is
      begin
         if Id = Res.No_Declaration then
            return False;
         end if;

         case Res.Sort_Of (Meanings.all, Id) is
            when Res.Named_Return =>
               return True;

            when Res.Local_Binding =>
               declare
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Id));
                  Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Id);
               begin
                  return Syn.Value_Of (Of_Tree.all, Node) = Syn.No_Node;
               end;

            when others =>
               return False;
         end case;
      end Is_Tracked;

      procedure Array_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Field   : out Natural)
      is
      begin
         Id := Res.No_Declaration;
         Field := 0;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Ill_Typed
         then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
         then
            Id := Res.Bound_To (Meanings.all, Of_Tree, Node);
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Which : constant Natural :=
                 Landin.Checking.Field_Index (Types.all, Of_Tree, Node);
            begin
               if Which not in 1 .. Widest_Struct then
                  return;
               end if;

               if Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                 and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                          = Res.Bound
               then
                  Id := Res.Bound_To (Meanings.all, Of_Tree, From);
                  Field := Which;
                  return;
               end if;

               if Syn.Kind (Of_Tree, From) = Syn.Member_Selection then
                  declare
                     Root : constant Syn.Node_Id :=
                       Syn.Target_Of (Of_Tree, From);
                     Parent : constant Natural :=
                       Landin.Checking.Field_Index
                         (Types.all, Of_Tree, From);
                  begin
                     if Parent in 1 .. Widest_Struct
                       and then Syn.Kind (Of_Tree, Root)
                                  = Syn.Name_Reference
                       and then Res.Verdict_Of
                         (Meanings.all, Of_Tree, Root) = Res.Bound
                     then
                        Id := Res.Bound_To (Meanings.all, Of_Tree, Root);
                        Field := Nested_Array_Path (Parent, Which);
                     end if;
                  end;
               end if;
            end;
         end if;
      end Array_Base;

      procedure Nested_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Parent  : out Tracked_Field;
         Child   : out Tracked_Field);

      procedure Nested_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Parent  : out Tracked_Field;
         Child   : out Tracked_Field)
      is
      begin
         Id := Res.No_Declaration;
         Parent := 0;
         Child := 0;
         if Syn.Kind (Of_Tree, Node) /= Syn.Member_Selection then
            return;
         end if;
         declare
            Middle : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
         begin
            if Syn.Kind (Of_Tree, Middle) /= Syn.Member_Selection then
               return;
            end if;
            declare
               Root : constant Syn.Node_Id :=
                 Syn.Target_Of (Of_Tree, Middle);
            begin
               if Syn.Kind (Of_Tree, Root) = Syn.Name_Reference
                 and then Res.Verdict_Of (Meanings.all, Of_Tree, Root)
                          = Res.Bound
                 and then Landin.Checking.Field_Index
                            (Types.all, Of_Tree, Middle)
                          in 1 .. Widest_Struct
                 and then Landin.Checking.Field_Index
                            (Types.all, Of_Tree, Node)
                          in 1 .. Widest_Struct
               then
                  Id := Res.Bound_To (Meanings.all, Of_Tree, Root);
                  Parent := Landin.Checking.Field_Index
                    (Types.all, Of_Tree, Middle);
                  Child := Landin.Checking.Field_Index
                    (Types.all, Of_Tree, Node);
               end if;
            end;
         end;
      end Nested_Base;

      procedure Require_Assigned
        (At_Source : Landin.Source.Source_Id;
         At_Span   : Landin.Source.Span;
         Id        : Res.Declaration_Id;
         State     : Assigned_Set;
         Message   : String;
         Field     : Tracked_Field := 0) is
      begin
         --  D16 assigns a struct a field at a time, so reading the whole
         --  of one wants every field: the first one no path assigned is
         --  the one to name, because a reader fixes them one at a time.
         if Field = 0
           and then Is_Tracked (Id)
           and then Landin.Checking.Has_Layout (Types.all, Id)
         then
            for Each in
              1 .. Landin.Checking.Layout_Field_Count (Types.all, Id)
            loop
               if Each in 1 .. Widest_Struct
                 and then
                   (case Landin.Checking.Field_Kind_Of
                           (Types.all,
                            Landin.Checking.Body_Of (Types.all, Id), Each)
                    is
                       when Landin.Checking.Scalar_Field =>
                         not State.Fields (Positive (Id), Each),
                       when Landin.Checking.Fixed_Array_Field =>
                         not Array_Is_Assigned (Id, Each, State),
                       when Landin.Checking.Aggregate_Field => False,
                       when Landin.Checking.Variant_Field =>
                         not State.Fields (Positive (Id), Each))
               then
                  Require_Assigned
                    (At_Source, At_Span, Id, State,
                     "the whole of `"
                     & Spelled (Res.Name_Of (Meanings.all, Id))
                     & "` is read here and no path that arrives assigned"
                     & " its `"
                     & Field_Named
                         (Landin.Checking.Body_Of (Types.all, Id), Each)
                     & "`",
                     Each);
                  return;
               end if;
            end loop;

            return;
         end if;

         if not Is_Tracked (Id)
           or else State.Fields (Positive (Id), Field)
         then
            return;
         end if;

         declare
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
         begin
            Bad.Report
              (Item    => Bad.Not_Definitely_Assigned,
               Source  => At_Source,
               Where   => At_Span,
               Message => Message,
               Note    => "[1910]: no condition is believed, so a name"
                          & " assigned in one arm of an `if` and not in"
                          & " another is not assigned after it",
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Assigned;

      function Array_Length_For
        (Id : Res.Declaration_Id; Field : Natural)
         return Landin.Checking.Element_Count
      is
      begin
         if Field = 0 then
            return Landin.Checking.Array_Length (Types.all, Id);
         end if;

         if Is_Nested_Array_Path (Field) then
            declare
               Parent_Body : constant Res.Declaration_Id :=
                 Landin.Checking.Body_Of (Types.all, Id);
               Child_Body : constant Res.Declaration_Id :=
                 Landin.Checking.Field_Shape_Of
                   (Types.all, Parent_Body, Array_Parent (Field))
                     .Aggregate_Body;
            begin
               return Landin.Checking.Field_Array_Length
                 (Types.all, Child_Body, Array_Child (Field));
            end;
         end if;

         return Landin.Checking.Field_Array_Length
                  (Types.all, Landin.Checking.Body_Of (Types.all, Id), Field);
      end Array_Length_For;

      function Array_Label
        (Id : Res.Declaration_Id; Field : Natural) return String
      is
         Outer_Body : constant Res.Declaration_Id :=
           Landin.Checking.Body_Of (Types.all, Id);
      begin
         if Field = 0 then
            return Spelled (Res.Name_Of (Meanings.all, Id));
         end if;

         if Is_Nested_Array_Path (Field) then
            declare
               Parent : constant Tracked_Field := Array_Parent (Field);
               Child_Body : constant Res.Declaration_Id :=
                 Landin.Checking.Field_Shape_Of
                   (Types.all, Outer_Body, Parent).Aggregate_Body;
            begin
               return Spelled (Res.Name_Of (Meanings.all, Id)) & "."
                 & Field_Named (Outer_Body, Parent) & "."
                 & Field_Named (Child_Body, Array_Child (Field));
            end;
         end if;

         return Spelled (Res.Name_Of (Meanings.all, Id)) & "."
           & Field_Named (Outer_Body, Field);
      end Array_Label;

      function Array_Is_Assigned
        (Id    : Res.Declaration_Id;
         Field : Natural;
         State : Assigned_Set) return Boolean
      is
         Assigned : Landin.Checking.Element_Count := 0;
      begin
         if not Is_Tracked (Id)
           or else Array_Sets.Contains (State.Whole_Arrays, (Id, Field))
           or else
             (Is_Nested_Array_Path (Field)
              and then State.Fields
                (Positive (Id), Array_Parent (Field)))
           or else Array_Length_For (Id, Field) = 0
         then
            return True;
         end if;

         --  D20: completeness is a count over the sparse facts that exist,
         --  never a walk over an array whose D18 length may fill the target.
         for Fact of State.Elements loop
            if Fact.Declaration = Id and then Fact.Field = Field then
               Assigned := Assigned + 1;
            end if;
         end loop;

         return Assigned = Array_Length_For (Id, Field);
      end Array_Is_Assigned;

      procedure Require_Array
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         State    : Assigned_Set;
         Field    : Natural := 0;
         Whole_As : Whole_Array_Read := Assignment_Source) is
      begin
         if Array_Is_Assigned (Id, Field, State) then
            return;
         end if;

         declare
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
         begin
            Bad.Report
              (Item    => Bad.Not_Definitely_Assigned,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "the whole of `"
                          & Array_Label (Id, Field)
                          & "` is read here and no path that arrives assigned"
                          & " every element",
               Note    =>
                 (case Whole_As is
                     when Assignment_Source =>
                       "D20: copying a local array reads every element",
                     when Initializer_Source =>
                       "D21: a local array initializer reads every element"
                       & " of its source"),
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Array;

      procedure Require_Computed_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         Field   : Natural;
         State   : Assigned_Set) is
      begin
         --  D22: a computed local index cannot be covered by D19's sparse
         --  facts, so the array must be assigned as a whole -- either by
         --  D20's copy or by D21's initializer, or by having as many sparse
         --  D19 facts as the array's declared length.  Only the local
         --  declared without a value is tracked; a parameter and a module
         --  binding fall through here as not tracked, and no tracked
         --  entity of an array type is anything else this kernel admits.
         if not Is_Tracked (Id)
           or else Array_Is_Assigned (Id, Field, State)
         then
            return;
         end if;

         declare
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
         begin
            Bad.Report
              (Item    => Bad.Not_Definitely_Assigned,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "`" & Array_Label (Id, Field)
                          & "` is read at a computed index and no path"
                          & " that arrives assigned it as a whole",
               Note    => "D22: a computed local array read requires the"
                          & " whole-array fact, because D19's element facts"
                          & " are compiler-known positions",
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Computed_Element;

      procedure Require_Element
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         Field    : Natural;
         Position : Ty.Magnitude;
         State    : Assigned_Set) is
      begin
         if not Is_Tracked (Id)
           or else Array_Sets.Contains (State.Whole_Arrays, (Id, Field))
           or else
             (Is_Nested_Array_Path (Field)
              and then State.Fields
                (Positive (Id), Array_Parent (Field)))
           or else Element_Sets.Contains
                     (State.Elements, (Id, Field, Position))
         then
            return;
         end if;

         declare
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
         begin
            Bad.Report
              (Item    => Bad.Not_Definitely_Assigned,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "`" & Array_Label (Id, Field)
                          & "[" & Written (Ty.Folded (Position))
                          & "]` is read here and no path that arrives"
                          & " assigned it",
               Note    => "D19: compiler-known elements of a local array"
                          & " are assigned independently",
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Element;

      --  Every read in an expression.  A place an assignment writes is not
      --  a read and is not walked here; `inc` is both and is walked.
      procedure Read_Names
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         State    : Assigned_Set;
         Whole_As : Whole_Array_Read := Assignment_Source) is
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         --  D19: reaching a known element is not a read of the whole array.
         --  D22: reaching a computed element of a tracked local *does*
         --  require the whole-array fact, because element facts are D19's
         --  compiler-known ones and no sparse fact covers a runtime index.
         --  The index is still an expression and is read first.  A refused
         --  or out-of-bounds selection establishes no additional diagnostic.
         if Syn.Kind (Of_Tree, Node) = Syn.Element_Index then
            declare
               From  : constant Syn.Node_Id :=
                 Syn.Target_Of (Of_Tree, Node);
               Where : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
               Position : Ty.Magnitude;
               Id : Res.Declaration_Id;
               Field : Natural;
            begin
               Read_Names (Of_Tree, Where, State);
               Array_Base (Of_Tree, From, Id, Field);
               if Id /= Res.No_Declaration
                 and then Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                            /= Ty.Ill_Typed
               then
                  if Known_Index_Value (Of_Tree, Where, Position) then
                     Require_Element
                       (Of_Tree, Node, Id, Field, Position, State);
                  else
                     Require_Computed_Element
                       (Of_Tree, Node, Id, Field, State);
                  end if;
               elsif Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       /= Ty.Ill_Typed
                 and then Syn.Kind (Of_Tree, From) /= Syn.Name_Reference
               then
                  Read_Names (Of_Tree, From, State);
               end if;
            end;

            return;
         end if;

         --  `lenof name` asks the name's fixed-array type for a constant;
         --  it neither reads nor reaches the array's storage.
         if Syn.Kind (Of_Tree, Node) = Syn.Len_Of then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference then
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 /= Ty.Ill_Typed
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                         = Res.Bound
            then
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       = Ty.Fixed_Array
                  then
                     Require_Array
                       (Of_Tree, Node, Id, State, Whole_As => Whole_As);
                  else
                     Require_Assigned
                       (Syn.Source_Of (Of_Tree), Syn.Where (Of_Tree, Node),
                        Id, State,
                        "`" & Spelled (Syn.Name (Of_Tree, Node))
                        & "` is read here and no path that arrives assigned"
                        & " it");
                  end if;
               end;
            end if;

            return;
         end if;

         --  D16: a field is assigned on its own, so reading one asks
         --  about that field and not about the name it is selected from.
         --  Reaching the field is not a read of the whole struct, which
         --  is why this does not walk into the base.
         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            --  D47: a refused array-field selection has no D16 fact.  Its
            --  type was made ill-typed by synthesis, so do not fall back to
            --  reading the whole local and add a second diagnostic.
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 = Ty.Ill_Typed
            then
               return;
            end if;

            declare
               Nested_Id : Res.Declaration_Id;
               Parent, Child : Tracked_Field;
            begin
               Nested_Base
                 (Of_Tree, Node, Nested_Id, Parent, Child);
               if Nested_Id /= Res.No_Declaration then
                  if Landin.Checking.Type_Of
                       (Types.all, Of_Tree, Node) = Ty.Fixed_Array
                  then
                     Require_Array
                       (Of_Tree, Node, Nested_Id, State,
                        Field => Nested_Array_Path (Parent, Child),
                        Whole_As => Whole_As);
                  elsif not Nested_Sets.Contains
                    (State.Nested, (Nested_Id, Parent, Child))
                  then
                     Require_Assigned
                       (Syn.Source_Of (Of_Tree), Syn.Where (Of_Tree, Node),
                        Nested_Id, State,
                        "this nested field is read here and no path that"
                        & " arrives assigned it",
                        Field => Parent);
                  end if;
                  return;
               end if;
            end;

            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Which : constant Natural :=
                 Landin.Checking.Field_Index (Types.all, Of_Tree, Node);
            begin
               if Which in 1 .. Widest_Struct
                 and then Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                 and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                          = Res.Bound
               then
                  declare
                     Id : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, From);
                  begin
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Node) = Ty.Fixed_Array
                     then
                        --  D50 reads a copy source as one whole fixed-array
                        --  field.  Its D48 sparse facts and D49/D50 whole
                        --  fact are separate from D16's scalar-field bit.
                        Require_Array
                          (Of_Tree, Node, Id, State,
                           Field => Which, Whole_As => Whole_As);
                     else
                        Require_Assigned
                          (Syn.Source_Of (Of_Tree),
                           Syn.Where (Of_Tree, Node), Id, State,
                           "`" & Spelled (Syn.Name (Of_Tree, From)) & "."
                           & Spelled (Syn.Name (Of_Tree, Node))
                           & "` is read here and no path that arrives"
                           & " assigned it",
                           Field => Which);
                     end if;
                  end;
               else
                  Read_Names (Of_Tree, From, State);
               end if;
            end;

            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Read_Names (Of_Tree, Syn.Slot (Of_Tree, Node, Position), State);
         end loop;
      end Read_Names;

      procedure Flow_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         Owner   : Landin.Provenance.Origin;
         State   : in out Assigned_Set;
         Exits   : out Boolean)
      is
         procedure Mark (Node : Syn.Node_Id);
         procedure Merge
           (Into   : in out Assigned_Set;
            First  : Boolean;
            Branch : Assigned_Set);

         procedure Merge
           (Into   : in out Assigned_Set;
            First  : Boolean;
            Branch : Assigned_Set) is
         begin
            if First then
               Into := Branch;
               return;
            end if;

            declare
               Left   : constant Assigned_Set := Into;
               Merged : Assigned_Set :=
                 (Fields       => Left.Fields,
                  Elements     => Element_Sets.Intersection
                                    (Left.Elements, Branch.Elements),
                  Whole_Arrays => Array_Sets.Intersection
                                    (Left.Whole_Arrays,
                                     Branch.Whole_Arrays),
                  Nested       => Nested_Sets.Intersection
                                    (Left.Nested, Branch.Nested));
            begin
               for Which in Tracked loop
                  for Part in Tracked_Field loop
                     Merged.Fields (Which, Part) :=
                       Left.Fields (Which, Part)
                       and Branch.Fields (Which, Part);
                  end loop;
               end loop;

               --  D20 gives a whole-array fact the meaning of every sparse
               --  element fact.  Intersecting whole with sparse therefore
               --  keeps the sparse side; intersecting two sparse states is
               --  the ordinary set intersection above.
               for Whole of Left.Whole_Arrays loop
                  if not Array_Sets.Contains (Branch.Whole_Arrays, Whole)
                  then
                     for Fact of Branch.Elements loop
                        if Fact.Declaration = Whole.Declaration
                          and then Fact.Field = Whole.Field
                        then
                           Element_Sets.Include (Merged.Elements, Fact);
                        end if;
                     end loop;
                  end if;
               end loop;

               for Whole of Branch.Whole_Arrays loop
                  if not Array_Sets.Contains (Left.Whole_Arrays, Whole) then
                     for Fact of Left.Elements loop
                        if Fact.Declaration = Whole.Declaration
                          and then Fact.Field = Whole.Field
                        then
                           Element_Sets.Include (Merged.Elements, Fact);
                        end if;
                     end loop;
                  end if;
               end loop;

               --  D89 gives a whole parent assignment the meaning of every
               --  nested array element.  Keep the other branch's sparse or
               --  whole nested-array representation when those facts meet.
               for Fact of Branch.Elements loop
                  if Is_Nested_Array_Path (Fact.Field)
                    and then Is_Tracked (Fact.Declaration)
                    and then Left.Fields
                      (Positive (Fact.Declaration),
                       Array_Parent (Fact.Field))
                  then
                     Element_Sets.Include (Merged.Elements, Fact);
                  end if;
               end loop;
               for Fact of Left.Elements loop
                  if Is_Nested_Array_Path (Fact.Field)
                    and then Is_Tracked (Fact.Declaration)
                    and then Branch.Fields
                      (Positive (Fact.Declaration),
                       Array_Parent (Fact.Field))
                  then
                     Element_Sets.Include (Merged.Elements, Fact);
                  end if;
               end loop;
               for Whole of Branch.Whole_Arrays loop
                  if Is_Nested_Array_Path (Whole.Field)
                    and then Is_Tracked (Whole.Declaration)
                    and then Left.Fields
                      (Positive (Whole.Declaration),
                       Array_Parent (Whole.Field))
                  then
                     Array_Sets.Include (Merged.Whole_Arrays, Whole);
                  end if;
               end loop;
               for Whole of Left.Whole_Arrays loop
                  if Is_Nested_Array_Path (Whole.Field)
                    and then Is_Tracked (Whole.Declaration)
                    and then Branch.Fields
                      (Positive (Whole.Declaration),
                       Array_Parent (Whole.Field))
                  then
                     Array_Sets.Include (Merged.Whole_Arrays, Whole);
                  end if;
               end loop;

               --  D88 gives assigning a whole ordinary child the meaning of
               --  assigning each nested scalar leaf.  Preserve the leaf from
               --  the other branch when the two representations meet.
               for Fact of Branch.Nested loop
                  if Is_Tracked (Fact.Declaration)
                    and then Left.Fields
                      (Positive (Fact.Declaration), Fact.Parent_Field)
                  then
                     Nested_Sets.Include (Merged.Nested, Fact);
                  end if;
               end loop;
               for Fact of Left.Nested loop
                  if Is_Tracked (Fact.Declaration)
                    and then Branch.Fields
                      (Positive (Fact.Declaration), Fact.Parent_Field)
                  then
                     Nested_Sets.Include (Merged.Nested, Fact);
                  end if;
               end loop;

               Into := Merged;
            end;
         end Merge;

         --  A place written is assigned from here on.
         procedure Mark (Node : Syn.Node_Id) is
         begin
            if Node /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Node) = Syn.Element_Index
            then
               declare
                  From  : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Where : constant Syn.Node_Id :=
                    Syn.Index_Of (Of_Tree, Node);
                  Position : Ty.Magnitude;
                  Id : Res.Declaration_Id;
                  Field : Natural;
               begin
                  --  Reaching an element destination reads its index even
                  --  though it does not read the element being selected.
                  Read_Names (Of_Tree, Where, State);
                  Array_Base (Of_Tree, From, Id, Field);
                  if Id /= Res.No_Declaration
                    and then Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                               /= Ty.Ill_Typed
                  then
                     if Known_Index_Value (Of_Tree, Where, Position)
                       and then Is_Tracked (Id)
                     then
                        Element_Sets.Include
                          (State.Elements, (Id, Field, Position));
                     end if;
                  elsif Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                          /= Ty.Ill_Typed
                    and then Syn.Kind (Of_Tree, From) /= Syn.Name_Reference
                  then
                     Read_Names (Of_Tree, From, State);
                  end if;
               end;

               return;
            end if;

            if Node /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            then
               --  A refused whole array field is not assignable and must not
               --  acquire a D16 fact through this recovery walk.  D48's
               --  element destination returned through the branch above;
               --  D49's contextual whole-field clear reaches this one.
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                    = Ty.Ill_Typed
               then
                  return;
               end if;

               declare
                  Nested_Id : Res.Declaration_Id;
                  Parent, Child : Tracked_Field;
               begin
                  Nested_Base
                    (Of_Tree, Node, Nested_Id, Parent, Child);
                  if Nested_Id /= Res.No_Declaration then
                     if Is_Tracked (Nested_Id) then
                        if Landin.Checking.Type_Of
                             (Types.all, Of_Tree, Node) = Ty.Fixed_Array
                        then
                           Array_Sets.Include
                             (State.Whole_Arrays,
                              (Nested_Id,
                               Nested_Array_Path (Parent, Child)));
                        else
                           Nested_Sets.Include
                             (State.Nested, (Nested_Id, Parent, Child));
                        end if;
                     end if;
                     return;
                  end if;
               end;

               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Which : constant Natural :=
                    Landin.Checking.Field_Index (Types.all, Of_Tree, Node);
               begin
                  if Which in 1 .. Widest_Struct
                    and then Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                    and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                             = Res.Bound
                  then
                     declare
                        Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, From);
                     begin
                        if Is_Tracked (Id) then
                           if Landin.Checking.Type_Of
                                (Types.all, Of_Tree, Node) = Ty.Fixed_Array
                           then
                              --  One compact fact covers a D18-sized field;
                              --  do not also mark the scalar-field table.
                              Array_Sets.Include
                                (State.Whole_Arrays, (Id, Which));
                           elsif Landin.Checking.Has_Layout (Types.all, Id)
                             and then Landin.Checking.Field_Kind_Of
                               (Types.all,
                                Landin.Checking.Body_Of (Types.all, Id),
                                Which) = Landin.Checking.Variant_Field
                           then
                              --  D77 reads the selected tag as one whole
                              --  variant-part fact.  D78's arm-local aliases
                              --  are available only after that case has been
                              --  selected, so they need no separate incoming
                              --  payload facts.
                              State.Fields
                                (Positive (Id), Which) := True;
                           else
                              State.Fields (Positive (Id), Which) := True;
                           end if;
                        end if;
                     end;
                  end if;
               end;

               return;
            end if;

            if Node /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                       = Res.Bound
            then
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Is_Tracked (Id) then
                     if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                          = Ty.Fixed_Array
                     then
                        --  One fact stands for an extent D18 permits to be
                        --  too large for either the IR or the host to list.
                        Array_Sets.Include (State.Whole_Arrays, (Id, 0));
                     else
                        State.Fields (Positive (Id), 0) := True;
                     end if;

                     --  A whole struct copied into a place assigns every
                     --  scalar field and every complete array field.  The
                     --  two facts stay in their D16 and D48 tables rather
                     --  than making an array field look scalar.
                     if Landin.Checking.Has_Layout (Types.all, Id) then
                        for Each in
                          1 .. Landin.Checking.Layout_Field_Count
                                 (Types.all, Id)
                        loop
                           if Each in 1 .. Widest_Struct then
                              case Landin.Checking.Field_Kind_Of
                                (Types.all,
                                 Landin.Checking.Body_Of (Types.all, Id),
                                 Each)
                              is
                                 when Landin.Checking.Scalar_Field =>
                                    State.Fields
                                      (Positive (Id), Each) := True;
                                 when Landin.Checking.Fixed_Array_Field =>
                                    Array_Sets.Include
                                      (State.Whole_Arrays, (Id, Each));
                                 when Landin.Checking.Aggregate_Field =>
                                    State.Fields
                                      (Positive (Id), Each) := True;
                                 when Landin.Checking.Variant_Field =>
                                    State.Fields
                                      (Positive (Id), Each) := True;
                              end case;
                           end if;
                        end loop;
                     end if;
                  end if;
               end;
            end if;
         end Mark;
      begin
         Exits := False;

         for Index in 1 .. Syn.Statement_Count (Of_Tree, Block) loop
            --  Nothing after an exit is reached, so nothing after one is
            --  asked about.
            exit when Exits;

            declare
               Item : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Of_Tree, Block, Index);
            begin
               case Syn.Kind (Of_Tree, Item) is
                  when Syn.Binding =>
                     --  [0110]: the value is read before the name exists,
                     --  so the read is checked and then the name is
                     --  assigned -- or not, if there is no value.
                     --  A local declared *with* a value is not tracked at
                     --  all, so there is nothing to mark: [1910] is about
                     --  the form [0080] describes, which has none.  D21
                     --  cites itself when a whole-array source is not
                     --  assigned, because that is what the reader is doing.
                     --  A declaration settled Ill_Typed is the binding-side
                     --  twin of an assignment's refused target below:
                     --  Check_Statement already returned after its owning
                     --  report, so the statement cannot execute and reads
                     --  nothing for definite assignment.
                     declare
                        Id : constant Res.Declaration_Id :=
                          Declaration_At
                            (Syn.Source_Of (Of_Tree), Item);
                     begin
                        if Id = Res.No_Declaration
                          or else Landin.Checking.Type_Of (Types.all, Id)
                                    /= Ty.Ill_Typed
                        then
                           Read_Names
                             (Of_Tree, Syn.Value_Of (Of_Tree, Item), State,
                              Whole_As => Initializer_Source);
                        end if;
                     end;

                  when Syn.Assignment =>
                     --  A refused destination owns the assignment report.
                     --  Check_Assignment marks the unvisited value ill-typed,
                     --  but a composite value still has children; do not walk
                     --  those children and add definite-assignment reports for
                     --  a statement that cannot be executed.  This also keeps
                     --  D52's immutable-root L0303 first and alone when a
                     --  literal element names the same local field.
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree,
                           Syn.Target_Of (Of_Tree, Item)) /= Ty.Ill_Typed
                     then
                        Read_Names
                          (Of_Tree, Syn.Value_Of (Of_Tree, Item), State);

                        --  D16: writing one field assigns that field and
                        --  says nothing about the others, and reaching it is
                        --  not a read of the struct it is in.
                        Mark (Syn.Target_Of (Of_Tree, Item));
                     end if;

                  when Syn.Increment | Syn.Decrement =>
                     --  [0400]: `inc x` is `x += 1`, so it reads x too.
                     Read_Names (Of_Tree, Syn.Target_Of (Of_Tree, Item),
                                 State);

                  when Syn.Discard | Syn.Call =>
                     Read_Names (Of_Tree, Item, State);

                  when Syn.Return_Statement =>
                     Read_Names (Of_Tree, Syn.Condition_Of (Of_Tree, Item),
                                 State);
                     --  A refused named return is no executable destination.
                     --  Its ABI report owns the declaration; do not follow it
                     --  with an assignment report at each `return`.
                     if Result = Res.No_Declaration
                       or else Landin.Checking.Type_Of (Types.all, Result)
                               /= Ty.Ill_Typed
                     then
                        Require_Assigned
                          (Syn.Source_Of (Of_Tree),
                           Syn.Anchor (Of_Tree, Item), Result, State,
                           "this returns and no path that arrives assigned"
                           & " the return");
                     end if;

                     --  [1910]: a `return when` is a return, and the flow
                     --  after it is reachable because the guard may be
                     --  false.  A bare one ends the block.
                     if Syn.Condition_Of (Of_Tree, Item) = Syn.No_Node then
                        Exits := True;
                     end if;

                  when Syn.If_Statement =>
                     declare
                        Merged   : Assigned_Set := Nothing_Assigned;
                        Any_Path : Boolean := False;
                        All_Exit : Boolean := True;
                     begin
                        for Arm in 1 .. Syn.Arm_Count (Of_Tree, Item) loop
                           declare
                              This : constant Syn.Node_Id :=
                                Syn.Nth_Arm (Of_Tree, Item, Arm);
                              Branch : Assigned_Set := State;
                              Left   : Boolean;
                           begin
                              Read_Names
                                (Of_Tree,
                                 Syn.Condition_Of (Of_Tree, This), State);
                              Flow_Block
                                (Of_Tree, Syn.Body_Of (Of_Tree, This),
                                 Result, Owner, Branch, Left);

                              if not Left then
                                 Merge (Merged, not Any_Path, Branch);
                                 Any_Path := True;
                                 All_Exit := False;
                              end if;
                           end;
                        end loop;

                        if Syn.Else_Body (Of_Tree, Item) /= Syn.No_Node
                        then
                           declare
                              Branch : Assigned_Set := State;
                              Left   : Boolean;
                           begin
                              Flow_Block
                                (Of_Tree, Syn.Else_Body (Of_Tree, Item),
                                 Result, Owner, Branch, Left);

                              if not Left then
                                 Merge (Merged, not Any_Path, Branch);
                                 Any_Path := True;
                                 All_Exit := False;
                              end if;
                           end;
                        else
                           --  [1910]: no condition is believed, so a
                           --  branch with no `else` has a path that runs
                           --  none of its arms and changes nothing.
                           Merge (Merged, not Any_Path, State);
                           Any_Path := True;
                           All_Exit := False;
                        end if;

                        if Any_Path then
                           State := Merged;
                        end if;

                        Exits := All_Exit;
                     end;

                  when Syn.Match_Statement =>
                     declare
                        Merged   : Assigned_Set := Nothing_Assigned;
                        Any_Path : Boolean := False;
                        All_Exit : Boolean := True;
                     begin
                        --  The tag is one incoming-state read.  Exhaustive
                        --  checking means every runtime path then enters
                        --  exactly one sibling arm.
                        Read_Names
                          (Of_Tree, Syn.Match_Subject (Of_Tree, Item), State);

                        for Arm in
                          1 .. Syn.Match_Arm_Count (Of_Tree, Item)
                        loop
                           declare
                              This : constant Syn.Node_Id :=
                                Syn.Nth_Match_Arm (Of_Tree, Item, Arm);
                              Branch : Assigned_Set := State;
                              Left   : Boolean;
                           begin
                              Flow_Block
                                (Of_Tree, Syn.Body_Of (Of_Tree, This),
                                 Result, Owner, Branch, Left);
                              if not Left then
                                 Merge (Merged, not Any_Path, Branch);
                                 Any_Path := True;
                                 All_Exit := False;
                              end if;
                           end;
                        end loop;

                        if Any_Path then
                           State := Merged;
                        end if;
                        Exits := All_Exit;
                     end;

                  when others =>
                     null;
               end case;
            end;
         end loop;
      end Flow_Block;

      Result_Id : constant Res.Declaration_Id :=
        (if Result_Node = Syn.No_Node then Res.No_Declaration
         else Declaration_At (Syn.Source_Of (Of_Tree), Result_Node));
      State : Assigned_Set := Nothing_Assigned;
      Exits : Boolean;
   begin
      Flow_Block
        (Of_Tree, Body_Node, Result_Id,
         Syn.Origin (Of_Tree, Function_Node), State, Exits);

      if not Exits
        and then
          (Result_Id = Res.No_Declaration
           or else Landin.Checking.Type_Of (Types.all, Result_Id)
                   /= Ty.Ill_Typed)
      then
         Require_Assigned
           (Syn.Source_Of (Of_Tree), Syn.Anchor (Of_Tree, Function_Node),
            Result_Id, State,
            "this function can reach its `end`"
            & " without assigning the return");
      end if;
   end Check_Function;

end Landin.Stages.Checking.Flow;
