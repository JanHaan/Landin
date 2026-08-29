with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

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
   package Unbounded renames Ada.Strings.Unbounded;
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

      --  D117's neutral path, on this side of the compiler: the run of
      --  declaration-order field identities from a tracked name down to
      --  the part a fact is about.  An empty run is the name itself, one
      --  step is a field of it, and [0420] puts no limit on the rest.
      --
      --  A run and not a pair packed into one integer.  Packing was what
      --  D88-D90 did with the parent and the child, and it stops working
      --  as soon as the field count raised to the depth leaves what a
      --  Natural holds -- silently, and with the wrong answer.
      package Field_Paths is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Tracked_Field);

      subtype Field_Path is Field_Paths.Vector;

      use type Field_Paths.Vector;

      No_Path : constant Field_Path := Field_Paths.Empty_Vector;

      function One (Field : Tracked_Field) return Field_Path
      is (Field_Paths.To_Vector (Field, 1));

      --  Lexicographic, so a set orders paths the way the source nests
      --  them and a shorter run sorts before anything extending it.
      function "<" (Left, Right : Field_Path) return Boolean;

      function "<" (Left, Right : Field_Path) return Boolean is
         Shorter : constant Natural :=
           Natural'Min (Natural (Left.Length), Natural (Right.Length));
      begin
         for Step in 1 .. Shorter loop
            if Left (Step) /= Right (Step) then
               return Left (Step) < Right (Step);
            end if;
         end loop;
         return Natural (Left.Length) < Natural (Right.Length);
      end "<";

      function Last (Path : Field_Path) return Tracked_Field
      is (Path (Positive (Path.Length)));

      type Assigned_Fields is array (Tracked, Tracked_Field) of Boolean;

      --  D121: an element of an array of ordinary structs is assigned a
      --  part at a time, exactly as a local struct is, so a fact names
      --  the run inside the element as well as the position.  An empty
      --  run is the whole element, which is what every array had before.
      type Element_Fact is record
         Declaration : Res.Declaration_Id;
         Path        : Field_Path;
         Position    : Ty.Magnitude;
         Below       : Field_Path;
      end record;

      function "<" (Left, Right : Element_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then
               (Left.Path < Right.Path
                or else
                  (Left.Path = Right.Path
                   and then
                     (Left.Position < Right.Position
                      or else
                        (Left.Position = Right.Position
                         and then Left.Below < Right.Below))))));

      package Element_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Element_Fact);

      type Array_Fact is record
         Declaration : Res.Declaration_Id;
         Path        : Field_Path;
      end record;

      function "<" (Left, Right : Array_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then Left.Path < Right.Path));

      package Array_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Array_Fact);

      --  A part reached by a run of two steps or more: a scalar leaf, or
      --  since D119 a whole child written as one.  The depth-one facts
      --  stay in the dense table above, which is the same question asked
      --  where it can be answered by indexing.
      type Nested_Fact is record
         Declaration : Res.Declaration_Id;
         Path        : Field_Path;
      end record;

      function "<" (Left, Right : Nested_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then Left.Path < Right.Path));

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
         Path    : out Field_Path);
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
         Path    : Field_Path;
         Position : Ty.Magnitude;
         State   : Assigned_Set;
         Below   : Field_Path := No_Path);
      procedure Require_Computed_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         Path    : Field_Path;
         State   : Assigned_Set);
      function Array_Length_For
        (Id : Res.Declaration_Id; Path : Field_Path)
         return Landin.Checking.Element_Count;
      function Array_Label
        (Id : Res.Declaration_Id; Path : Field_Path) return String;
      function Array_Is_Assigned
        (Id    : Res.Declaration_Id;
         Path  : Field_Path;
         State : Assigned_Set) return Boolean;
      procedure Require_Array
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         State    : Assigned_Set;
         Path     : Field_Path := No_Path;
         Whole_As : Whole_Array_Read := Assignment_Source);

      --  Whether a fact about this part already follows from one about
      --  something containing it.  [0540]'s whole-storage forms make that
      --  the ordinary case, and D117 makes "containing" mean "named by a
      --  shorter run with the same steps".  The run itself counts, so a
      --  caller asking about a whole child gets the same answer either
      --  way; Strictly_Above asks about the containers alone.
      function Covered
        (Id    : Res.Declaration_Id;
         Path  : Field_Path;
         State : Assigned_Set;
         Strictly_Above : Boolean := False) return Boolean;

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

      --  The whole of one selection chain [0420], resolved once.  Id is
      --  the bound name it started from and Path is every selection from
      --  that name in source order, so a caller asks about depth by
      --  looking at the run rather than by writing one out.
      procedure Chain_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path);

      procedure Chain_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path)
      is
         Steps : Field_Path;
         Where : Syn.Node_Id := Node;
      begin
         Id := Res.No_Declaration;
         Path := No_Path;

         while Syn.Kind (Of_Tree, Where) = Syn.Member_Selection loop
            declare
               Which : constant Natural :=
                 Landin.Checking.Field_Index (Types.all, Of_Tree, Where);
            begin
               if Which not in 1 .. Widest_Struct then
                  return;
               end if;
               Steps.Prepend (Which);
               Where := Syn.Target_Of (Of_Tree, Where);
            end;
         end loop;

         if Syn.Kind (Of_Tree, Where) /= Syn.Name_Reference
           or else Res.Verdict_Of (Meanings.all, Of_Tree, Where) /= Res.Bound
         then
            return;
         end if;

         Id := Res.Bound_To (Meanings.all, Of_Tree, Where);
         Path := Steps;
      end Chain_Base;

      --  D121: the one index in a selection chain, what reaches the array
      --  above it, and the run inside the element below it.  The same
      --  three questions the lowering asks, asked here so a fact names
      --  exactly the part a write established.
      function Chain_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function Chain_Above
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function Chain_Below
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Field_Path;

      function Chain_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
      is
         Where : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Of_Tree, Where) = Syn.Member_Selection loop
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         if Syn.Kind (Of_Tree, Where) = Syn.Element_Index then
            return Where;
         end if;
         return Syn.No_Node;
      end Chain_Index;

      function Chain_Above
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
      is
         Indexed : constant Syn.Node_Id := Chain_Index (Of_Tree, Node);
      begin
         if Indexed = Syn.No_Node then
            return Node;
         end if;
         return Syn.Target_Of (Of_Tree, Indexed);
      end Chain_Above;

      function Chain_Below
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Field_Path
      is
         Steps : Field_Path;
         Where : Syn.Node_Id := Node;
      begin
         if Chain_Index (Of_Tree, Node) = Syn.No_Node then
            return No_Path;
         end if;

         while Syn.Kind (Of_Tree, Where) = Syn.Member_Selection loop
            declare
               Which : constant Natural :=
                 Landin.Checking.Field_Index (Types.all, Of_Tree, Where);
            begin
               if Which not in 1 .. Widest_Struct then
                  return No_Path;
               end if;
               Steps.Prepend (Which);
               Where := Syn.Target_Of (Of_Tree, Where);
            end;
         end loop;
         return Steps;
      end Chain_Below;

      procedure Array_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path)
      is
      begin
         Id := Res.No_Declaration;
         Path := No_Path;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Ill_Typed
         then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) not in
              Syn.Name_Reference | Syn.Member_Selection
         then
            return;
         end if;

         Chain_Base (Of_Tree, Node, Id, Path);
      end Array_Base;

      --  The same chain, when what it names sits two steps or more below
      --  the name: the facts for those live in the sparse set rather than
      --  in the dense per-field table.
      procedure Nested_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path);

      procedure Nested_Base
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path)
      is
         use type Ada.Containers.Count_Type;
      begin
         Chain_Base (Of_Tree, Node, Id, Path);
         if Path.Length < 2 then
            Id := Res.No_Declaration;
            Path := No_Path;
         end if;
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
                         not Array_Is_Assigned (Id, One (Each), State),
                       when Landin.Checking.Aggregate_Field =>
                         not State.Fields (Positive (Id), Each),
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
           or else (Field = 0
                    and then Landin.Checking.Type_Of (Types.all, Id)
                               = Ty.Fixed_Array
                    and then Array_Is_Assigned (Id, No_Path, State))
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

      --  The body that holds the part a run reaches, and the shape of
      --  that part.  One walk down the declaration-order shapes, which is
      --  the same walk Landin.IR.Shape_At does over neutral ones.
      function Held_By
        (Id : Res.Declaration_Id; Path : Field_Path)
         return Res.Declaration_Id;

      function Held_By
        (Id : Res.Declaration_Id; Path : Field_Path)
         return Res.Declaration_Id
      is
         Where : Res.Declaration_Id :=
           Landin.Checking.Body_Of (Types.all, Id);
      begin
         for Step in 1 .. Natural (Path.Length) - 1 loop
            Where := Landin.Checking.Field_Shape_Of
              (Types.all, Where, Path (Step)).Aggregate_Body;
         end loop;
         return Where;
      end Held_By;

      function Covered
        (Id    : Res.Declaration_Id;
         Path  : Field_Path;
         State : Assigned_Set;
         Strictly_Above : Boolean := False) return Boolean
      is
         Depth : constant Natural := Natural (Path.Length);
         Deepest : constant Natural :=
           (if Strictly_Above then Natural'Max (0, Depth - 1) else Depth);
      begin
         if not Is_Tracked (Id) then
            return False;
         end if;

         --  The name itself, which is column zero of the dense table.
         if State.Fields (Positive (Id), 0) then
            return True;
         end if;

         for Length in 1 .. Deepest loop
            if Length = 1 then
               if State.Fields (Positive (Id), Path (1)) then
                  return True;
               end if;
            else
               declare
                  Prefix : Field_Path;
               begin
                  for Step in 1 .. Length loop
                     Prefix.Append (Path (Step));
                  end loop;
                  if Nested_Sets.Contains (State.Nested, (Id, Prefix)) then
                     return True;
                  end if;
               end;
            end if;
         end loop;

         return False;
      end Covered;

      function Array_Length_For
        (Id : Res.Declaration_Id; Path : Field_Path)
         return Landin.Checking.Element_Count
      is
      begin
         if Path.Is_Empty then
            return Landin.Checking.Array_Length (Types.all, Id);
         end if;

         return Landin.Checking.Field_Array_Length
                  (Types.all, Held_By (Id, Path), Last (Path));
      end Array_Length_For;

      function Array_Label
        (Id : Res.Declaration_Id; Path : Field_Path) return String
      is
         Where : Res.Declaration_Id :=
           Landin.Checking.Body_Of (Types.all, Id);
         Text  : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String
             (Spelled (Res.Name_Of (Meanings.all, Id)));
      begin
         for Step in 1 .. Natural (Path.Length) loop
            Unbounded.Append (Text, "." & Field_Named (Where, Path (Step)));
            if Step < Natural (Path.Length) then
               Where := Landin.Checking.Field_Shape_Of
                 (Types.all, Where, Path (Step)).Aggregate_Body;
            end if;
         end loop;
         return Unbounded.To_String (Text);
      end Array_Label;

      function Array_Is_Assigned
        (Id    : Res.Declaration_Id;
         Path  : Field_Path;
         State : Assigned_Set) return Boolean
      is
         Assigned : Landin.Checking.Element_Count := 0;
      begin
         if not Is_Tracked (Id)
           or else Array_Sets.Contains (State.Whole_Arrays, (Id, Path))
           or else Covered (Id, Path, State, Strictly_Above => True)
           or else Array_Length_For (Id, Path) = 0
         then
            return True;
         end if;

         --  D20: completeness is a count over the sparse facts that exist,
         --  never a walk over an array whose D18 length may fill the target.
         for Fact of State.Elements loop
            if Fact.Declaration = Id
              and then Fact.Path = Path
              and then Fact.Below.Is_Empty
            then
               Assigned := Assigned + 1;
            end if;
         end loop;

         return Assigned = Array_Length_For (Id, Path);
      end Array_Is_Assigned;

      procedure Require_Array
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         State    : Assigned_Set;
         Path     : Field_Path := No_Path;
         Whole_As : Whole_Array_Read := Assignment_Source) is
      begin
         if Array_Is_Assigned (Id, Path, State) then
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
                          & Array_Label (Id, Path)
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
         Path    : Field_Path;
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
           or else Array_Is_Assigned (Id, Path, State)
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
               Message => "`" & Array_Label (Id, Path)
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
         Path     : Field_Path;
         Position : Ty.Magnitude;
         State    : Assigned_Set;
         Below    : Field_Path := No_Path) is
      begin
         --  A fact about the whole element covers every part of it, so a
         --  read of a part asks for either.
         if not Is_Tracked (Id)
           or else Array_Sets.Contains (State.Whole_Arrays, (Id, Path))
           or else Covered (Id, Path, State, Strictly_Above => True)
           or else Element_Sets.Contains
                     (State.Elements, (Id, Path, Position, No_Path))
           or else Element_Sets.Contains
                     (State.Elements, (Id, Path, Position, Below))
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
               Message => "`" & Array_Label (Id, Path)
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
               Path : Field_Path;
            begin
               Read_Names (Of_Tree, Where, State);
               Array_Base (Of_Tree, From, Id, Path);
               if Id /= Res.No_Declaration
                 and then Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                            /= Ty.Ill_Typed
               then
                  if Known_Index_Value (Of_Tree, Where, Position) then
                     Require_Element
                       (Of_Tree, Node, Id, Path, Position, State);
                  else
                     Require_Computed_Element
                       (Of_Tree, Node, Id, Path, State);
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

         --  `lenof name` asks only for a type constant.  Forming an
         --  anonymous function likewise forms one static code address; its
         --  separately checked no-capture body reads nothing in this flow.
         if Syn.Kind (Of_Tree, Node)
              in Syn.Len_Of | Syn.Anonymous_Function
         then
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

            --  D121: a chain through an index reads a part of an element,
            --  not a field of a name.
            if Chain_Index (Of_Tree, Node) /= Syn.No_Node then
               declare
                  Indexed : constant Syn.Node_Id :=
                    Chain_Index (Of_Tree, Node);
                  Where : constant Syn.Node_Id :=
                    Syn.Index_Of (Of_Tree, Indexed);
                  Position : Ty.Magnitude;
                  Id : Res.Declaration_Id;
                  Path : Field_Path;
               begin
                  Read_Names (Of_Tree, Where, State);
                  Array_Base
                    (Of_Tree, Chain_Above (Of_Tree, Node), Id, Path);
                  if Id /= Res.No_Declaration then
                     if Known_Index_Value (Of_Tree, Where, Position) then
                        Require_Element
                          (Of_Tree, Node, Id, Path, Position, State,
                           Below => Chain_Below (Of_Tree, Node));
                     else
                        Require_Computed_Element
                          (Of_Tree, Node, Id, Path, State);
                     end if;
                  end if;
               end;

               return;
            end if;

            declare
               Nested_Id : Res.Declaration_Id;
               Path : Field_Path;
            begin
               Nested_Base (Of_Tree, Node, Nested_Id, Path);
               if Nested_Id /= Res.No_Declaration then
                  if Landin.Checking.Type_Of
                       (Types.all, Of_Tree, Node) = Ty.Fixed_Array
                  then
                     Require_Array
                       (Of_Tree, Node, Nested_Id, State,
                        Path => Path, Whole_As => Whole_As);
                  elsif not Covered (Nested_Id, Path, State) then
                     Require_Assigned
                       (Syn.Source_Of (Of_Tree), Syn.Where (Of_Tree, Node),
                        Nested_Id, State,
                        "`" & Array_Label (Nested_Id, Path)
                        & "` is read here and no path that arrives assigned"
                        & " it",
                        Field => Path (1));
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
                           Path => One (Which), Whole_As => Whole_As);
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
                          and then Fact.Path = Whole.Path
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
                          and then Fact.Path = Whole.Path
                        then
                           Element_Sets.Include (Merged.Elements, Fact);
                        end if;
                     end loop;
                  end if;
               end loop;

               --  D89 gives assigning anything containing an array the
               --  meaning of every element fact below it, and D88 the same
               --  for a nested scalar leaf.  D117 makes "containing" mean
               --  "named by a shorter run", so one question covers both and
               --  covers a chain of any depth.
               for Fact of Branch.Elements loop
                  if Covered (Fact.Declaration, Fact.Path, Left,
                              Strictly_Above => True)
                  then
                     Element_Sets.Include (Merged.Elements, Fact);
                  end if;
               end loop;
               for Fact of Left.Elements loop
                  if Covered (Fact.Declaration, Fact.Path, Branch,
                              Strictly_Above => True)
                  then
                     Element_Sets.Include (Merged.Elements, Fact);
                  end if;
               end loop;
               for Whole of Branch.Whole_Arrays loop
                  if Covered (Whole.Declaration, Whole.Path, Left,
                              Strictly_Above => True)
                  then
                     Array_Sets.Include (Merged.Whole_Arrays, Whole);
                  end if;
               end loop;
               for Whole of Left.Whole_Arrays loop
                  if Covered (Whole.Declaration, Whole.Path, Branch,
                              Strictly_Above => True)
                  then
                     Array_Sets.Include (Merged.Whole_Arrays, Whole);
                  end if;
               end loop;
               for Fact of Branch.Nested loop
                  if Covered (Fact.Declaration, Fact.Path, Left,
                              Strictly_Above => True)
                  then
                     Nested_Sets.Include (Merged.Nested, Fact);
                  end if;
               end loop;
               for Fact of Left.Nested loop
                  if Covered (Fact.Declaration, Fact.Path, Branch,
                              Strictly_Above => True)
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
                  Path : Field_Path;
               begin
                  --  Reaching an element destination reads its index even
                  --  though it does not read the element being selected.
                  Read_Names (Of_Tree, Where, State);
                  Array_Base (Of_Tree, From, Id, Path);
                  if Id /= Res.No_Declaration
                    and then Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                               /= Ty.Ill_Typed
                  then
                     if Known_Index_Value (Of_Tree, Where, Position)
                       and then Is_Tracked (Id)
                     then
                        Element_Sets.Include
                          (State.Elements,
                           (Id, Path, Position, No_Path));
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

               if Chain_Index (Of_Tree, Node) /= Syn.No_Node then
                  declare
                     Indexed : constant Syn.Node_Id :=
                       Chain_Index (Of_Tree, Node);
                     Where : constant Syn.Node_Id :=
                       Syn.Index_Of (Of_Tree, Indexed);
                     Position : Ty.Magnitude;
                     Id : Res.Declaration_Id;
                     Path : Field_Path;
                  begin
                     Read_Names (Of_Tree, Where, State);
                     Array_Base
                       (Of_Tree, Chain_Above (Of_Tree, Node), Id, Path);
                     if Id /= Res.No_Declaration
                       and then Is_Tracked (Id)
                       and then Known_Index_Value (Of_Tree, Where, Position)
                     then
                        Element_Sets.Include
                          (State.Elements,
                           (Id, Path, Position,
                            Chain_Below (Of_Tree, Node)));
                     end if;
                  end;

                  return;
               end if;

               declare
                  Nested_Id : Res.Declaration_Id;
                  Path : Field_Path;
               begin
                  Nested_Base (Of_Tree, Node, Nested_Id, Path);
                  if Nested_Id /= Res.No_Declaration then
                     if Is_Tracked (Nested_Id) then
                        if Landin.Checking.Type_Of
                             (Types.all, Of_Tree, Node) = Ty.Fixed_Array
                        then
                           Array_Sets.Include
                             (State.Whole_Arrays, (Nested_Id, Path));
                        else
                           Nested_Sets.Include
                             (State.Nested, (Nested_Id, Path));
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
                                (State.Whole_Arrays, (Id, One (Which)));
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
                        Array_Sets.Include
                          (State.Whole_Arrays, (Id, No_Path));
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
                                      (State.Whole_Arrays, (Id, One (Each)));
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
