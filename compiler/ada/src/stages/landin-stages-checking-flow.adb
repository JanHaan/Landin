with Ada.Containers;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Cleanup;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Syntax.Forest;
with Landin.Types;

package body Landin.Stages.Checking.Flow is

   package Bad renames Landin.Diagnostics.Checking;
   package Cleanup renames Landin.Cleanup;
   package Unbounded renames Ada.Strings.Unbounded;
   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Ada.Containers.Count_Type;
   use type Landin.Provenance.Declaration_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Types.Type_Kind;
   use type Landin.Types.Magnitude;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Field_Kind;
   use type Landin.Checking.Signature_Id;
   use type Landin.Checking.Routine_Instance_Id;
   use type Syn.Parameter_Convention;
   use type Res.Verdict;
   use type Res.Application_Class;
   use type Res.Argument_Role;
   use type Res.Declaration_Sort;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;

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
        (Nominal : Landin.Checking.Nominal_Type_Id;
         Index   : Positive) return String;

      function Field_Named
        (Nominal : Landin.Checking.Nominal_Type_Id;
         Index   : Positive) return String
      is
         Wrote : constant Res.Declaration_Id :=
           Landin.Checking.Template_Of (Types.all, Nominal);
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
                  elsif Syn.Kind (Of_Tree.all, Node) = Syn.Return_List then
                     Most := Natural'Max
                       (Most, Syn.Slot_Count (Of_Tree.all, Node));
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

      --  D118's neutral path, on this side of the compiler: the run of
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
         --  [0910]'s use-after-consume facts are separate from ordinary
         --  definite assignment: initialized locals and parameters are live
         --  without appearing in Fields, but a sink makes one exact place
         --  dead until a later assignment revives it.
         Dead_Fields  : Assigned_Fields := [others => [others => False]];
         Dead_Elements : Element_Sets.Set;
         Dead_Nested  : Nested_Sets.Set;
      end record;

      Nothing_Assigned : constant Assigned_Set :=
        (Fields        => [others => [others => False]],
         Elements      => Element_Sets.Empty_Set,
         Whole_Arrays  => Array_Sets.Empty_Set,
         Nested        => Nested_Sets.Empty_Set,
         Dead_Fields   => [others => [others => False]],
         Dead_Elements => Element_Sets.Empty_Set,
         Dead_Nested   => Nested_Sets.Empty_Set);

      --  D124 replaces the old Boolean "this block exits" summary.  A
      --  guarded return has both edges, an unconditional return only the
      --  second, and a value-producing block only needs an answer on the
      --  first.  The assignment state below always describes that explicit
      --  fallthrough edge; returned edges have already been validated where
      --  the return occurred.
      type Edge_Facts is record
         Falls_Through : Boolean := False;
         Returns       : Boolean := False;
      end record;

      No_Edges : constant Edge_Facts := (others => False);
      Fallthrough_Edge : constant Edge_Facts :=
        (Falls_Through => True, Returns => False);

      --  A lexical cleanup stack contains syntax, not evaluated arguments.
      --  Reaching defer or undo appends its call; an applicable block edge
      --  walks active entries in reverse and only then evaluates each call.
      --  Active is cleared before an entry runs so a return from one of its
      --  arguments unwinds the still-pending entries without repeating it.
      type Cleanup_Entry is record
         Kind   : Cleanup.Cleanup_Kind := Cleanup.Deferred_Call;
         Call   : Syn.Node_Id := Syn.No_Node;
         Active : Boolean := True;
      end record;

      package Cleanup_Entries is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Cleanup_Entry);

      package Cleanup_Indexes is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Positive);

      Cleanup_Stack : Cleanup_Entries.Vector;

      type Loop_Cleanup_Entry is record
         Label        : Landin.Source.Names.Name_Id :=
           Landin.Source.Names.No_Name;
         Cleanup_Base : Natural := 0;
      end record;

      package Loop_Cleanup_Entries is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Loop_Cleanup_Entry);

      --  The cleanup depth outside each active loop.  A transfer unwinds
      --  only lexical frames entered since that loop began, then either
      --  reaches the loop exit or its next condition test.
      Loop_Cleanup_Stack : Loop_Cleanup_Entries.Vector;

      function Transfer_Loop
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Loop_Cleanup_Entry;

      function Transfer_Loop
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Loop_Cleanup_Entry
      is
         Target : constant Landin.Source.Names.Name_Id :=
           Syn.Name (Of_Tree, Node);
      begin
         for Index in reverse 1 .. Natural (Loop_Cleanup_Stack.Length) loop
            declare
               Candidate : constant Loop_Cleanup_Entry :=
                 Loop_Cleanup_Stack (Index);
            begin
               if Target = Landin.Source.Names.No_Name
                 or else Candidate.Label = Target
               then
                  return Candidate;
               end if;
            end;
         end loop;
         raise Landin.Compiler_Defect with "a loop transfer has no target";
      end Transfer_Loop;

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
      procedure Place_Identity
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path;
         Position : out Ty.Magnitude;
         Is_Element : out Boolean;
         Valid   : out Boolean);
      procedure Consume_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; State : in out Assigned_Set);
      procedure Revive_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; State : in out Assigned_Set);
      function Require_Live
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; State : Assigned_Set)
         return Boolean;
      procedure Flow_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         State   : in out Assigned_Set;
         Edges   : out Edge_Facts;
         Whole_As : Whole_Array_Read := Assignment_Source);
      function Contains_Control
        (Of_Tree : Syn.Tree; Root : Syn.Node_Id) return Boolean;
      procedure Flow_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         Owner   : Landin.Provenance.Origin;
         State   : in out Assigned_Set;
         Edges   : out Edge_Facts;
         Needs_Value : Boolean := False);
      procedure Flow_Cleanups
        (Of_Tree : Syn.Tree;
         First   : Natural;
         On_Exit : Cleanup.Exit_Kind;
         Result  : Res.Declaration_Id;
         State   : in out Assigned_Set;
         Edges   : out Edge_Facts);
      procedure Merge
        (Into   : in out Assigned_Set;
         First  : Boolean;
         Branch : Assigned_Set);
      procedure Require_Assigned
        (At_Source : Landin.Source.Source_Id;
         At_Span   : Landin.Source.Span;
         Id        : Res.Declaration_Id;
         State     : Assigned_Set;
         Message   : String;
         Field     : Tracked_Field := 0);
      procedure Require_Returns_Assigned
        (At_Span : Landin.Source.Span;
         State   : Assigned_Set;
         Message : String);
      procedure Require_Inout_Places_Live
        (At_Span : Landin.Source.Span; State : Assigned_Set);
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
      --  the ordinary case, and D118 makes "containing" mean "named by a
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
         Field     : Tracked_Field := 0)
      is
         procedure Report_Unassigned (Why : String);

         procedure Report_Unassigned (Why : String)
         is
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
         begin
            Bad.Report
              (Item    => Bad.Not_Definitely_Assigned,
               Source  => At_Source,
               Where   => At_Span,
               Message => Why,
               Note    => "[1910]: no condition is believed, so a name"
                          & " assigned in one arm of an `if` and not in"
                          & " another is not assigned after it",
               Related => Landin.Provenance.Origin'
                 (Source => Res.Source_Of (Meanings.all, Id),
                  Where  => Syn.Anchor (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end Report_Unassigned;
      begin
         --  D16 assigns a struct a field at a time, so reading the whole
         --  of one wants every field: the first one no path assigned is
         --  the one to name, because a reader fixes them one at a time.
         if Field = 0
           and then Is_Tracked (Id)
           and then Landin.Checking.Has_Layout
             (Types.all, Landin.Checking.Nominal_Of (Types.all, Id))
         then
            for Each in
              1 .. Landin.Checking.Layout_Field_Count
                (Types.all, Landin.Checking.Nominal_Of (Types.all, Id))
            loop
               if Each in 1 .. Widest_Struct then
                  declare
                     Kind : constant Landin.Checking.Field_Kind :=
                       Landin.Checking.Field_Kind_Of
                         (Types.all,
                          Landin.Checking.Nominal_Of (Types.all, Id), Each);
                     Missing : Boolean;
                  begin
                     case Kind is
                        when Landin.Checking.Fixed_Array_Field =>
                           Missing := not Array_Is_Assigned
                             (Id, One (Each), State);
                        when Landin.Checking.Scalar_Field
                           | Landin.Checking.Reference_Field
                           | Landin.Checking.Aggregate_Field
                           | Landin.Checking.Variant_Field =>
                           Missing :=
                             not State.Fields (Positive (Id), Each);
                     end case;

                     if Missing then
                        Report_Unassigned
                          ("the whole of `"
                           & Spelled (Res.Name_Of (Meanings.all, Id))
                           & "` is read here and no path that arrives"
                           & " assigned its `"
                           & Field_Named
                               (Landin.Checking.Nominal_Of (Types.all, Id),
                                Each)
                           & "`");
                        return;
                     end if;
                  end;
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

         Report_Unassigned (Message);
      end Require_Assigned;

      procedure Require_Returns_Assigned
        (At_Span : Landin.Source.Span;
         State   : Assigned_Set;
         Message : String) is
      begin
         for Which in 1 .. Syn.Return_Count (Of_Tree, Function_Node) loop
            declare
               Returned : constant Syn.Node_Id :=
                 Syn.Nth_Return (Of_Tree, Function_Node, Which);
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Syn.Source_Of (Of_Tree), Returned);
            begin
               if Id = Res.No_Declaration
                 or else Landin.Checking.Type_Of (Types.all, Id)
                           /= Ty.Ill_Typed
               then
                  Require_Assigned
                    (Syn.Source_Of (Of_Tree), At_Span, Id, State,
                     Message & " `" & Spelled (Syn.Name (Of_Tree, Returned))
                     & "`");
               end if;
            end;
         end loop;
      end Require_Returns_Assigned;

      procedure Require_Inout_Places_Live
        (At_Span : Landin.Source.Span; State : Assigned_Set)
      is
      begin
         for Position in 1 .. Syn.Parameter_Count (Of_Tree, Function_Node)
         loop
            declare
               Parameter : constant Syn.Node_Id :=
                 Syn.Nth_Parameter (Of_Tree, Function_Node, Position);
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Syn.Source_Of (Of_Tree), Parameter);
               Dead : Boolean := False;
            begin
               if Syn.Convention_Of (Of_Tree, Parameter)
                    = Syn.Inout_Convention
               then
                  for Field in Tracked_Field loop
                     Dead := Dead
                       or else State.Dead_Fields (Positive (Id), Field);
                  end loop;
                  for Fact of State.Dead_Nested loop
                     Dead := Dead or else Fact.Declaration = Id;
                  end loop;
                  for Fact of State.Dead_Elements loop
                     Dead := Dead or else Fact.Declaration = Id;
                  end loop;
                  if Dead then
                     Bad.Report
                       (Item    => Bad.Not_Definitely_Assigned,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => At_Span,
                        Message => "this returns with a place sunk out of an"
                                   & " `inout` parameter still dead",
                        Note    => "[0910]: a consumed part of `inout` must"
                                   & " be assigned again before return",
                        Related => Syn.Origin (Of_Tree, Parameter),
                        Because => "the `inout` parameter",
                        Into    => Found);
                     return;
                  end if;
               end if;
            end;
         end loop;
      end Require_Inout_Places_Live;

      --  The body that holds the part a run reaches, and the shape of
      --  that part.  One walk down the declaration-order shapes, which is
      --  the same walk Landin.IR.Shape_At does over neutral ones.
      function Held_By
        (Id : Res.Declaration_Id; Path : Field_Path)
         return Landin.Checking.Nominal_Type_Id;

      function Held_By
        (Id : Res.Declaration_Id; Path : Field_Path)
         return Landin.Checking.Nominal_Type_Id
      is
         Shape : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Result_Shape_Of (Types.all, Id);
         Where : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Id);
         First : Positive := 1;
      begin
         if Shape /= Landin.Checking.No_Signature
           and then not Path.Is_Empty
         then
            Where := Landin.Checking.Nth_Signature_Result
              (Types.all, Shape, Positive (Path (1))).Nominal;
            First := 2;
         end if;
         for Step in First .. Natural (Path.Length) - 1 loop
            Where := Landin.Checking.Field_Shape_Of
              (Types.all, Where, Path (Step)).Nominal;
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

         if Landin.Checking.Result_Shape_Of (Types.all, Id)
              /= Landin.Checking.No_Signature
           and then Natural (Path.Length) = 1
         then
            return Landin.Checking.Nth_Signature_Result
              (Types.all,
               Landin.Checking.Result_Shape_Of (Types.all, Id),
               Positive (Path (1))).Length;
         end if;

         return Landin.Checking.Field_Array_Length
                  (Types.all, Held_By (Id, Path), Last (Path));
      end Array_Length_For;

      function Array_Label
        (Id : Res.Declaration_Id; Path : Field_Path) return String
      is
         Shape : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Result_Shape_Of (Types.all, Id);
         Where : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Id);
         Text  : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String
             (Spelled (Res.Name_Of (Meanings.all, Id)));
         First : Positive := 1;
      begin
         if Shape /= Landin.Checking.No_Signature
           and then not Path.Is_Empty
         then
            declare
               Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Result
                   (Types.all, Shape, Positive (Path (1)));
            begin
               Unbounded.Append (Text, "." & Spelled (Part.Name));
               Where := Part.Nominal;
               First := 2;
            end;
         end if;
         for Step in First .. Natural (Path.Length) loop
            Unbounded.Append (Text, "." & Field_Named (Where, Path (Step)));
            if Step < Natural (Path.Length) then
               Where := Landin.Checking.Field_Shape_Of
                 (Types.all, Where, Path (Step)).Nominal;
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

      procedure Place_Identity
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : out Res.Declaration_Id;
         Path    : out Field_Path;
         Position : out Ty.Magnitude;
         Is_Element : out Boolean;
         Valid   : out Boolean)
      is
         Indexed : constant Syn.Node_Id := Chain_Index (Of_Tree, Node);
      begin
         Id := Res.No_Declaration;
         Path := No_Path;
         Position := 0;
         Is_Element := False;
         Valid := False;

         if Indexed /= Syn.No_Node then
            declare
               Where : constant Syn.Node_Id :=
                 Syn.Index_Of (Of_Tree, Indexed);
            begin
               Array_Base
                 (Of_Tree, Chain_Above (Of_Tree, Node), Id, Path);
               if Id /= Res.No_Declaration
                 and then Known_Index_Value (Of_Tree, Where, Position)
               then
                  Is_Element := True;
                  Path.Append (Chain_Below (Of_Tree, Node));
                  Valid := True;
               end if;
               return;
            end;
         end if;

         Chain_Base (Of_Tree, Node, Id, Path);
         Valid := Id /= Res.No_Declaration;
      end Place_Identity;

      procedure Consume_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; State : in out Assigned_Set)
      is
         Id : Res.Declaration_Id;
         Path : Field_Path;
         Position : Ty.Magnitude;
         Is_Element : Boolean;
         Valid : Boolean;
      begin
         Place_Identity
           (Of_Tree, Node, Id, Path, Position, Is_Element, Valid);
         if not Valid then
            return;
         elsif Is_Element then
            Element_Sets.Include
              (State.Dead_Elements,
               (Id, No_Path, Position, Path));
         elsif Path.Is_Empty then
            State.Dead_Fields (Positive (Id), 0) := True;
         elsif Path.Length = 1 then
            State.Dead_Fields (Positive (Id), Last (Path)) := True;
         else
            Nested_Sets.Include (State.Dead_Nested, (Id, Path));
         end if;
      end Consume_Place;

      procedure Revive_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; State : in out Assigned_Set)
      is
         Id : Res.Declaration_Id;
         Path : Field_Path;
         Position : Ty.Magnitude;
         Is_Element : Boolean;
         Valid : Boolean;
      begin
         Place_Identity
           (Of_Tree, Node, Id, Path, Position, Is_Element, Valid);
         if not Valid then
            return;
         elsif Is_Element then
            Element_Sets.Exclude
              (State.Dead_Elements,
               (Id, No_Path, Position, Path));
         elsif Path.Is_Empty then
            State.Dead_Fields (Positive (Id), 0) := False;
         elsif Path.Length = 1 then
            State.Dead_Fields (Positive (Id), Last (Path)) := False;
         else
            Nested_Sets.Exclude (State.Dead_Nested, (Id, Path));
         end if;
      end Revive_Place;

      function Require_Live
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; State : Assigned_Set)
         return Boolean
      is
         Id : Res.Declaration_Id;
         Path : Field_Path;
         Position : Ty.Magnitude;
         Is_Element : Boolean;
         Valid : Boolean;
         Dead : Boolean := False;
      begin
         if Syn.Kind (Of_Tree, Node)
           not in Syn.Name_Reference | Syn.Member_Selection
              | Syn.Element_Index
         then
            return True;
         end if;
         Place_Identity
           (Of_Tree, Node, Id, Path, Position, Is_Element, Valid);
         if not Valid then
            return True;
         end if;

         Dead := State.Dead_Fields (Positive (Id), 0);
         if Is_Element then
            Dead := Dead or else Element_Sets.Contains
              (State.Dead_Elements, (Id, No_Path, Position, Path));
         elsif not Path.Is_Empty then
            Dead := Dead
              or else State.Dead_Fields (Positive (Id), Path (1));
            if Path.Length > 1 then
               Dead := Dead or else Nested_Sets.Contains
                 (State.Dead_Nested, (Id, Path));
            end if;
         end if;
         if not Dead then
            return True;
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
               Message => "this place was consumed by `sink` and has not"
                          & " been assigned again",
               Note    => "[0910]: a sunk place is dead until assignment",
               Related => Syn.Origin (Their_Tree.all, Their_Node),
               Because => "the binding containing the consumed place",
               Into    => Found);
         end;
         return False;
      end Require_Live;

      --  Definite assignment meets only fallthrough states.  The compact
      --  whole-array and whole-child facts imply their sparse descendants,
      --  so their intersection retains the same representation bridges the
      --  former statement-only branch merge used.
      procedure Merge
        (Into   : in out Assigned_Set;
         First  : Boolean;
         Branch : Assigned_Set)
      is
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
                                 (Left.Nested, Branch.Nested),
               Dead_Fields  => Left.Dead_Fields,
               Dead_Elements => Element_Sets.Union
                                  (Left.Dead_Elements,
                                   Branch.Dead_Elements),
               Dead_Nested  => Nested_Sets.Union
                                  (Left.Dead_Nested, Branch.Dead_Nested));
         begin
            for Which in Tracked loop
               for Part in Tracked_Field loop
                  Merged.Fields (Which, Part) :=
                    Left.Fields (Which, Part)
                    and Branch.Fields (Which, Part);
                  Merged.Dead_Fields (Which, Part) :=
                    Left.Dead_Fields (Which, Part)
                    or Branch.Dead_Fields (Which, Part);
               end loop;
            end loop;

            for Whole of Left.Whole_Arrays loop
               if not Array_Sets.Contains (Branch.Whole_Arrays, Whole) then
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

         if not Require_Live (Of_Tree, Node, State) then
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
               if Landin.Checking.Type_Of (Types.all, Of_Tree, From)
                    = Ty.Slice_Value
               then
                  Read_Names (Of_Tree, From, State);
                  Read_Names (Of_Tree, Where, State);
                  return;
               end if;
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

      function Contains_Control
        (Of_Tree : Syn.Tree; Root : Syn.Node_Id) return Boolean
      is
      begin
         if Root = Syn.No_Node then
            return False;
         end if;

         if Syn.Kind (Of_Tree, Root)
              in Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
                 | Syn.Loop_Statement | Syn.While_Statement
                 | Syn.For_Statement
         then
            return True;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Root) loop
            if Contains_Control
                 (Of_Tree, Syn.Slot (Of_Tree, Root, Position))
            then
               return True;
            end if;
         end loop;
         return False;
      end Contains_Control;

      procedure Flow_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         State   : in out Assigned_Set;
         Edges   : out Edge_Facts;
         Whole_As : Whole_Array_Read := Assignment_Source)
      is
         Needs_Value : constant Boolean :=
           Node /= Syn.No_Node
           and then Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
             in Ty.Scalar_Name | Ty.Fixed_Array | Ty.Aggregate
                | Ty.Function_Value | Ty.Atom_Value;
      begin
         if Node = Syn.No_Node then
            Edges := Fallthrough_Edge;
            return;
         end if;

         Edges := No_Edges;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               declare
                  Is_While : constant Boolean :=
                    Syn.Kind (Of_Tree, Node) = Syn.While_Statement;
                  Is_For : constant Boolean :=
                    Syn.Kind (Of_Tree, Node) = Syn.For_Statement;
                  Returned : Boolean := False;
                  Completion_Falls_Through : Boolean := False;

                  procedure Mark_Iteration
                    (Binding : Syn.Node_Id; Into : in out Assigned_Set);

                  procedure Mark_Iteration
                    (Binding : Syn.Node_Id; Into : in out Assigned_Set)
                  is
                     Id : constant Res.Declaration_Id :=
                       Declaration_At (Syn.Source_Of (Of_Tree), Binding);
                  begin
                     if Id = Res.No_Declaration or else not Is_Tracked (Id)
                     then
                        return;
                     end if;
                     Into.Fields (Positive (Id), 0) := True;

                     --  D160: a struct element is a whole struct the
                     --  traversed storage already holds, so every one of
                     --  its parts arrives assigned, as a copied struct's do.
                     if Landin.Checking.Type_Of (Types.all, Id) = Ty.Aggregate
                       and then Landin.Checking.Has_Layout
                         (Types.all,
                          Landin.Checking.Nominal_Of (Types.all, Id))
                     then
                        for Each in
                          1 .. Landin.Checking.Layout_Field_Count
                            (Types.all,
                             Landin.Checking.Nominal_Of (Types.all, Id))
                        loop
                           if Each in 1 .. Widest_Struct then
                              if Landin.Checking.Field_Kind_Of
                                (Types.all,
                                 Landin.Checking.Nominal_Of (Types.all, Id),
                                 Each) = Landin.Checking.Fixed_Array_Field
                              then
                                 Array_Sets.Include
                                   (Into.Whole_Arrays, (Id, One (Each)));
                              else
                                 Into.Fields (Positive (Id), Each) := True;
                              end if;
                           end if;
                        end loop;
                     end if;
                  end Mark_Iteration;
               begin
                  if Is_While then
                     declare
                        Test_Edges : Edge_Facts;
                     begin
                        Flow_Expression
                          (Of_Tree, Syn.Condition_Of (Of_Tree, Node),
                           Result, State, Test_Edges);
                        Returned := Test_Edges.Returns;
                        if not Test_Edges.Falls_Through then
                           Edges := Test_Edges;
                           return;
                        end if;
                     end;
                  end if;

                  if Is_For then
                     declare
                        Bound_Edges : Edge_Facts;
                     begin
                        Flow_Expression
                          (Of_Tree, Syn.Traversal_Lower (Of_Tree, Node),
                           Result, State, Bound_Edges);
                        Returned := Returned or Bound_Edges.Returns;
                        if not Bound_Edges.Falls_Through then
                           Edges := Bound_Edges;
                           return;
                        end if;
                        if Syn.Traversal_Upper (Of_Tree, Node)
                             /= Syn.No_Node
                        then
                           Flow_Expression
                             (Of_Tree, Syn.Traversal_Upper (Of_Tree, Node),
                              Result, State, Bound_Edges);
                           Returned := Returned or Bound_Edges.Returns;
                           if not Bound_Edges.Falls_Through then
                              Edges := Bound_Edges;
                              return;
                           end if;
                        end if;
                     end;
                  end if;

                  declare
                     Body_State : Assigned_Set := State;
                     Body_Edges : Edge_Facts;
                  begin
                     if Is_For then
                        Mark_Iteration
                          (Syn.Traversal_Element (Of_Tree, Node), Body_State);
                        if Syn.Traversal_Index (Of_Tree, Node) /= Syn.No_Node
                        then
                           Mark_Iteration
                             (Syn.Traversal_Index (Of_Tree, Node), Body_State);
                        end if;
                     end if;
                     Loop_Cleanup_Stack.Append
                       (Loop_Cleanup_Entry'
                          (Label        => Syn.Name (Of_Tree, Node),
                           Cleanup_Base => Natural (Cleanup_Stack.Length)));
                     Flow_Block
                       (Of_Tree, Syn.Loop_Body (Of_Tree, Node), Result,
                        Syn.Origin (Of_Tree, Node), Body_State, Body_Edges);
                     Returned := Returned or Body_Edges.Returns;

                     if Syn.Complete_Body (Of_Tree, Node) /= Syn.No_Node then
                        declare
                           Complete_State : Assigned_Set := State;
                           Complete_Edges : Edge_Facts;
                        begin
                           Flow_Block
                             (Of_Tree, Syn.Complete_Body (Of_Tree, Node),
                              Result, Syn.Origin (Of_Tree, Node),
                              Complete_State, Complete_Edges);
                           Returned := Returned or Complete_Edges.Returns;
                           Completion_Falls_Through :=
                             Complete_Edges.Falls_Through;
                        end;
                     end if;
                     Loop_Cleanup_Stack.Delete_Last;
                  end;

                  if Needs_Value and then (Is_While or else Is_For)
                    and then
                      (Syn.Complete_Body (Of_Tree, Node) = Syn.No_Node
                       or else Completion_Falls_Through)
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where
                          (Of_Tree,
                           (if Syn.Complete_Body (Of_Tree, Node) = Syn.No_Node
                            then Node
                            else Syn.Complete_Body (Of_Tree, Node))),
                        Message => "this value-producing loop can finish"
                          & " without a value",
                        Note    => "[1190]: `complete` must leave through"
                          & " `break with` when a finite loop is an"
                          & " expression",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "this value-producing loop",
                        Into    => Found);
                  end if;

                  --  A while's false test and an unconditional loop's
                  --  break edges are the only exits.  This first increment
                  --  deliberately retains only facts present before an
                  --  iteration; a later fixed-point refinement may prove
                  --  more without weakening definite assignment.
                  Edges := (Falls_Through => True, Returns => Returned);
               end;

            when Syn.If_Statement =>
               declare
                  Remaining : Assigned_Set := State;
                  Merged    : Assigned_Set := Nothing_Assigned;
                  Any_Path  : Boolean := False;
                  Can_Test  : Boolean := True;
                  Returned  : Boolean := False;
               begin
                  for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                     exit when not Can_Test;
                     declare
                        This : constant Syn.Node_Id :=
                          Syn.Nth_Arm (Of_Tree, Node, Arm);
                        Test_Edges : Edge_Facts;
                     begin
                        Flow_Expression
                          (Of_Tree, Syn.Condition_Of (Of_Tree, This),
                           Result, Remaining, Test_Edges);
                        Returned := Returned or Test_Edges.Returns;
                        Can_Test := Test_Edges.Falls_Through;

                        if Can_Test then
                           declare
                              Branch : Assigned_Set := Remaining;
                              Branch_Edges : Edge_Facts;
                           begin
                              Flow_Block
                                (Of_Tree, Syn.Body_Of (Of_Tree, This),
                                 Result, Syn.Origin (Of_Tree, Node),
                                 Branch, Branch_Edges, Needs_Value);
                              Returned := Returned or Branch_Edges.Returns;
                              if Branch_Edges.Falls_Through then
                                 Merge (Merged, not Any_Path, Branch);
                                 Any_Path := True;
                              end if;
                           end;
                        end if;
                     end;
                  end loop;

                  if Can_Test then
                     if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                        declare
                           Branch : Assigned_Set := Remaining;
                           Branch_Edges : Edge_Facts;
                        begin
                           Flow_Block
                             (Of_Tree, Syn.Else_Body (Of_Tree, Node),
                              Result, Syn.Origin (Of_Tree, Node),
                              Branch, Branch_Edges, Needs_Value);
                           Returned := Returned or Branch_Edges.Returns;
                           if Branch_Edges.Falls_Through then
                              Merge (Merged, not Any_Path, Branch);
                              Any_Path := True;
                           end if;
                        end;
                     else
                        if Needs_Value then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Node),
                              Message => "this value-producing `if` has a"
                                         & " fallthrough path with no value",
                              Note    => "D124: every fallthrough edge of a"
                                         & " control expression produces its"
                                         & " joined value",
                              Related => Syn.Origin
                                (Of_Tree,
                                 Syn.Condition_Of
                                   (Of_Tree,
                                    Syn.Nth_Arm (Of_Tree, Node, 1))),
                              Because => "this condition has an untaken"
                                         & " edge",
                              Into    => Found);
                        end if;
                        Merge (Merged, not Any_Path, Remaining);
                        Any_Path := True;
                     end if;
                  end if;

                  if Any_Path then
                     State := Merged;
                  end if;
                  Edges :=
                    (Falls_Through => Any_Path, Returns => Returned);
               end;

            when Syn.Match_Statement =>
               declare
                  Subject_Edges : Edge_Facts;
               begin
                  Flow_Expression
                    (Of_Tree, Syn.Match_Subject (Of_Tree, Node),
                     Result, State, Subject_Edges);
                  if not Subject_Edges.Falls_Through then
                     Edges := Subject_Edges;
                     return;
                  end if;

                  declare
                     Incoming : constant Assigned_Set := State;
                     Merged   : Assigned_Set := Nothing_Assigned;
                     Any_Path : Boolean := False;
                     Returned : Boolean := Subject_Edges.Returns;
                  begin
                     for Arm in
                       1 .. Syn.Match_Arm_Count (Of_Tree, Node)
                     loop
                        declare
                           This : constant Syn.Node_Id :=
                             Syn.Nth_Match_Arm (Of_Tree, Node, Arm);
                           Branch : Assigned_Set := Incoming;
                           Branch_Edges : Edge_Facts;
                        begin
                           Flow_Block
                             (Of_Tree, Syn.Body_Of (Of_Tree, This),
                              Result, Syn.Origin (Of_Tree, Node),
                              Branch, Branch_Edges, Needs_Value);
                           Returned := Returned or Branch_Edges.Returns;
                           if Branch_Edges.Falls_Through then
                              Merge (Merged, not Any_Path, Branch);
                              Any_Path := True;
                           end if;
                        end;
                     end loop;

                     if Any_Path then
                        State := Merged;
                     end if;
                     Edges :=
                       (Falls_Through => Any_Path, Returns => Returned);
                  end;
               end;

            when Syn.Bare_Block =>
               Flow_Block
                 (Of_Tree, Syn.Body_Of (Of_Tree, Node), Result,
                  Syn.Origin (Of_Tree, Node), State, Edges, Needs_Value);

            when Syn.Call | Syn.Labeled_Application =>
               --  D131: a direct declaration needs no runtime read, but an
               --  indirect callee is an ordinary function value and may be a
               --  field or indexed field with its own DA and control edges.
               Edges := Fallthrough_Edge;
               if Syn.Kind (Of_Tree, Node) = Syn.Call
                 or else Res.Class_Of (Meanings.all, Of_Tree, Node)
                            = Res.Function_Call
               then
                  Flow_Expression
                    (Of_Tree, Syn.Callee_Of (Of_Tree, Node), Result,
                     State, Edges, Whole_As);
               end if;
               for Index in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
                  exit when not Edges.Falls_Through;
                  declare
                     Raw : constant Syn.Node_Id :=
                       Syn.Nth_Argument (Of_Tree, Node, Index);
                     Argument : constant Syn.Node_Id :=
                       (if Syn.Kind (Of_Tree, Raw) = Syn.Call_Argument
                          and then Res.Role_Of
                            (Meanings.all, Of_Tree, Raw)
                              in Res.Runtime_Argument | Res.Field_Argument
                                 | Res.Payload_Argument | Res.Fill_Argument
                        then Syn.Expression_Projection (Of_Tree, Raw)
                        elsif Syn.Kind (Of_Tree, Raw) = Syn.Call_Argument
                        then Syn.No_Node
                        else Raw);
                     Part : Edge_Facts;
                  begin
                     if Argument /= Syn.No_Node then
                        Flow_Expression
                          (Of_Tree, Argument, Result, State, Part, Whole_As);
                        Edges.Returns := Edges.Returns or Part.Returns;
                        Edges.Falls_Through := Part.Falls_Through;

                        if Edges.Falls_Through
                          and then (Syn.Kind (Of_Tree, Node) = Syn.Call
                                    or else Res.Class_Of
                                      (Meanings.all, Of_Tree, Node)
                                        = Res.Function_Call)
                        then
                           declare
                              Target : constant
                                Landin.Checking.Routine_Instance_Id :=
                                  Landin.Checking.Routine_Target_Of
                                    (Types.all, Of_Tree, Node);
                              Callee : constant Syn.Node_Id :=
                                Syn.Callee_Of (Of_Tree, Node);
                              Node_Signature : constant
                                Landin.Checking.Signature_Id :=
                                  Landin.Checking.Signature_Of
                                    (Types.all, Of_Tree, Callee);
                              Signature : constant
                                Landin.Checking.Signature_Id :=
                                  (if Target /= Landin.Checking
                                                   .No_Routine_Instance
                                   then Landin.Checking.Routine_Signature_Of
                                     (Types.all, Target)
                                   elsif Node_Signature /=
                                     Landin.Checking.No_Signature
                                   then Node_Signature
                                   elsif Syn.Kind (Of_Tree, Callee)
                                     = Syn.Name_Reference
                                     and then Res.Verdict_Of
                                       (Meanings.all, Of_Tree, Callee)
                                         = Res.Bound
                                   then Landin.Checking.Signature_Of
                                     (Types.all,
                                      Res.Bound_To
                                        (Meanings.all, Of_Tree, Callee))
                                   else Landin.Checking.No_Signature);
                              Formal : constant Positive :=
                                (if Syn.Kind (Of_Tree, Raw)
                                      = Syn.Call_Argument
                                 then Positive
                                   (Res.Position_Of
                                      (Meanings.all, Of_Tree, Raw))
                                 else Index);
                           begin
                              if Signature /= Landin.Checking.No_Signature
                                and then Formal <=
                                  Landin.Checking.Signature_Parameter_Count
                                    (Types.all, Signature)
                                and then Landin.Checking
                                  .Nth_Signature_Parameter
                                    (Types.all, Signature, Formal).Convention
                                      = Syn.Sink_Convention
                              then
                                 Consume_Place
                                   (Of_Tree, Argument, State);
                              end if;
                           end;
                        end if;
                     end if;
                  end;
               end loop;

               if Edges.Falls_Through
                 and then (Syn.Kind (Of_Tree, Node) = Syn.Call
                           or else Res.Class_Of
                             (Meanings.all, Of_Tree, Node)
                               = Res.Function_Call)
                 and then Syn.Recovery_Of (Of_Tree, Node) /= Syn.No_Node
               then
                  declare
                     Recovery : constant Syn.Node_Id :=
                       Syn.Recovery_Of (Of_Tree, Node);
                     Recovery_Body : constant Syn.Node_Id :=
                       Syn.Else_Body (Of_Tree, Recovery);
                     Recovered : Assigned_Set := State;
                     Recovery_Edges : Edge_Facts;
                  begin
                     if Syn.Kind (Of_Tree, Recovery_Body) = Syn.Block then
                        Flow_Block
                          (Of_Tree, Recovery_Body, Result,
                           Syn.Origin (Of_Tree, Recovery), Recovered,
                           Recovery_Edges, Needs_Value);
                     else
                        Flow_Expression
                          (Of_Tree, Recovery_Body, Result, Recovered,
                           Recovery_Edges, Whole_As);
                     end if;
                     Edges.Returns :=
                       Edges.Returns or Recovery_Edges.Returns;
                     if Recovery_Edges.Falls_Through then
                        --  Both success and recovered fallthrough reach the
                        --  consumer, so only facts true on both survive.
                        Merge (State, False, Recovered);
                     end if;
                     --  The successful call edge always continues.
                     Edges.Falls_Through := True;
                  end;
               end if;

            when Syn.Try_Expression =>
               Flow_Expression
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Result,
                  State, Edges, Whole_As);
               --  The call may fail after evaluating its arguments.  Run
               --  every active failure-applicable cleanup on that edge; the
               --  success edge keeps this state and continues.
               if Edges.Falls_Through then
                  declare
                     Failure_State : Assigned_Set := State;
                     Cleanup_Edges : Edge_Facts;
                  begin
                     Flow_Cleanups
                       (Of_Tree, 1, Cleanup.Failure_Propagation,
                        Result, Failure_State, Cleanup_Edges);
                     Edges.Returns := Edges.Returns
                       or Cleanup_Edges.Returns
                       or Cleanup_Edges.Falls_Through;
                  end;
               end if;

            when Syn.Logical_And | Syn.Logical_Or =>
               --  [0340]/[0410]: after the left operand falls through, one
               --  edge skips the right and one evaluates it.  A return from
               --  the right therefore cannot erase the skip edge or lend
               --  right-only assignment facts to it.
               Flow_Expression
                 (Of_Tree, Syn.Left_Of (Of_Tree, Node), Result,
                  State, Edges, Whole_As);
               if Edges.Falls_Through then
                  declare
                     Skipped : constant Assigned_Set := State;
                     Taken   : Assigned_Set := State;
                     Right_Edges : Edge_Facts;
                     Returned : constant Boolean := Edges.Returns;
                  begin
                     Flow_Expression
                       (Of_Tree, Syn.Right_Of (Of_Tree, Node), Result,
                        Taken, Right_Edges, Whole_As);
                     State := Skipped;
                     if Right_Edges.Falls_Through then
                        Merge (State, False, Taken);
                     end if;
                     Edges :=
                       (Falls_Through => True,
                        Returns => Returned or Right_Edges.Returns);
                  end;
               end if;

            when Syn.Element_Index =>
               --  [0410]: an index runs before the selected element is
               --  read.  A control-valued index may return, so only its
               --  fallthrough edge reaches the assignment fact check.
               declare
                  From  : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Where : constant Syn.Node_Id :=
                    Syn.Index_Of (Of_Tree, Node);
                  Position : Ty.Magnitude;
                  Id : Res.Declaration_Id;
                  Path : Field_Path;
               begin
                  Flow_Expression
                    (Of_Tree, Where, Result, State, Edges);
                  if not Edges.Falls_Through then
                     return;
                  end if;

                  Array_Base (Of_Tree, From, Id, Path);
                  if Id /= Res.No_Declaration
                    and then Landin.Checking.Type_Of
                      (Types.all, Of_Tree, Node) /= Ty.Ill_Typed
                  then
                     if Known_Index_Value (Of_Tree, Where, Position) then
                        Require_Element
                          (Of_Tree, Node, Id, Path, Position, State);
                     else
                        Require_Computed_Element
                          (Of_Tree, Node, Id, Path, State);
                     end if;
                  elsif Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Node) /= Ty.Ill_Typed
                    and then Syn.Kind (Of_Tree, From)
                                   /= Syn.Name_Reference
                  then
                     Read_Names (Of_Tree, From, State);
                  end if;
               end;

            when others =>
               if not Contains_Control (Of_Tree, Node) then
                  Read_Names (Of_Tree, Node, State, Whole_As);
                  Edges := Fallthrough_Edge;
                  return;
               end if;

               --  A control expression nested under an ordinary operator,
               --  call or literal is evaluated in slot/source order.  A
               --  returned edge stops later operands; only the surviving
               --  fallthrough state reaches them.
               Edges := Fallthrough_Edge;
               for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
                  exit when not Edges.Falls_Through;
                  declare
                     Part : Edge_Facts;
                  begin
                     Flow_Expression
                       (Of_Tree, Syn.Slot (Of_Tree, Node, Position),
                        Result, State, Part, Whole_As);
                     Edges.Returns := Edges.Returns or Part.Returns;
                     Edges.Falls_Through := Part.Falls_Through;
                  end;
               end loop;
         end case;
      end Flow_Expression;

      procedure Flow_Cleanups
        (Of_Tree : Syn.Tree;
         First   : Natural;
         On_Exit : Cleanup.Exit_Kind;
         Result  : Res.Declaration_Id;
         State   : in out Assigned_Set;
         Edges   : out Edge_Facts)
      is
         Disabled : Cleanup_Indexes.Vector;
         Last : constant Natural := Natural (Cleanup_Stack.Length);
      begin
         Edges := Fallthrough_Edge;
         if First = 0 or else First > Last then
            return;
         end if;

         for Position in reverse Positive (First) .. Positive (Last) loop
            exit when not Edges.Falls_Through;

            declare
               Action : Cleanup_Entry := Cleanup_Stack (Position);
            begin
               if Action.Active
                 and then Cleanup.Applies (Action.Kind, On_Exit)
               then
                  Action.Active := False;
                  Cleanup_Stack.Replace_Element (Position, Action);
                  Disabled.Append (Position);

                  declare
                     Step : Edge_Facts;
                  begin
                     Flow_Expression
                       (Of_Tree, Action.Call, Result, State, Step);
                     Edges.Returns := Edges.Returns or Step.Returns;
                     Edges.Falls_Through := Step.Falls_Through;
                  end;
               end if;
            end;
         end loop;

         --  This walk represents one possible exit.  Restore its entries so
         --  a sibling edge through the same syntax gets its own runtime
         --  execution.  A nested return skipped every entry this walk had
         --  already disabled, so it cannot have added one of these indexes.
         for Position of Disabled loop
            declare
               Action : Cleanup_Entry := Cleanup_Stack (Position);
            begin
               Action.Active := True;
               Cleanup_Stack.Replace_Element (Position, Action);
            end;
         end loop;
      end Flow_Cleanups;

      procedure Flow_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         Owner   : Landin.Provenance.Origin;
         State   : in out Assigned_Set;
         Edges   : out Edge_Facts;
         Needs_Value : Boolean := False)
      is
         Cleanup_Base : constant Natural := Natural (Cleanup_Stack.Length);
         procedure Mark
           (Node              : Syn.Node_Id;
            Index_Was_Checked : Boolean := False);

         --  A place written is assigned from here on.
         procedure Mark
           (Node              : Syn.Node_Id;
            Index_Was_Checked : Boolean := False)
         is
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
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, From)
                       = Ty.Slice_Value
                  then
                     Read_Names (Of_Tree, From, State);
                     if not Index_Was_Checked then
                        Read_Names (Of_Tree, Where, State);
                     end if;
                     return;
                  end if;

                  --  Reaching an element destination reads its index even
                  --  though it does not read the element being selected.
                  if not Index_Was_Checked then
                     Read_Names (Of_Tree, Where, State);
                  end if;
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
                           elsif Landin.Checking.Has_Layout
                             (Types.all,
                              Landin.Checking.Nominal_Of (Types.all, Id))
                             and then Landin.Checking.Field_Kind_Of
                               (Types.all,
                                Landin.Checking.Nominal_Of (Types.all, Id),
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
                     if Landin.Checking.Has_Layout
                       (Types.all, Landin.Checking.Nominal_Of (Types.all, Id))
                     then
                        for Each in
                          1 .. Landin.Checking.Layout_Field_Count
                            (Types.all,
                             Landin.Checking.Nominal_Of (Types.all, Id))
                        loop
                           if Each in 1 .. Widest_Struct then
                              case Landin.Checking.Field_Kind_Of
                                (Types.all,
                                 Landin.Checking.Nominal_Of (Types.all, Id),
                                 Each)
                              is
                                 when Landin.Checking.Scalar_Field
                                    | Landin.Checking.Reference_Field =>
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
         Edges := Fallthrough_Edge;

         for Index in 1 .. Syn.Statement_Count (Of_Tree, Block) loop
            exit when not Edges.Falls_Through;

            declare
               Item : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Of_Tree, Block, Index);
               Step : Edge_Facts := Fallthrough_Edge;
            begin
               case Syn.Kind (Of_Tree, Item) is
                  when Syn.Binding =>
                     declare
                        Id : constant Res.Declaration_Id :=
                          Declaration_At (Syn.Source_Of (Of_Tree), Item);
                     begin
                        if Id = Res.No_Declaration
                          or else Landin.Checking.Type_Of (Types.all, Id)
                                    /= Ty.Ill_Typed
                        then
                           Flow_Expression
                             (Of_Tree, Syn.Value_Of (Of_Tree, Item), Result,
                              State, Step, Initializer_Source);
                        end if;
                     end;

                  when Syn.Destructuring_Binding =>
                     Flow_Expression
                       (Of_Tree, Syn.Destructured_Value (Of_Tree, Item),
                        Result, State, Step, Initializer_Source);

                  when Syn.Assignment =>
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree,
                           Syn.Target_Of (Of_Tree, Item)) /= Ty.Ill_Typed
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Item);
                           Checked_Index : constant Boolean :=
                             Syn.Kind (Of_Tree, Place) = Syn.Element_Index;
                        begin
                           if Checked_Index then
                              Flow_Expression
                                (Of_Tree, Syn.Index_Of (Of_Tree, Place),
                                 Result, State, Step);
                           end if;

                           if Step.Falls_Through then
                              declare
                                 Value_Edges : Edge_Facts;
                              begin
                                 Flow_Expression
                                   (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                                    Result, State, Value_Edges);
                                 Step.Returns :=
                                   Step.Returns or Value_Edges.Returns;
                                 Step.Falls_Through :=
                                   Value_Edges.Falls_Through;
                              end;
                           end if;

                           if Step.Falls_Through then
                              Mark
                                (Place,
                                 Index_Was_Checked => Checked_Index);
                              Revive_Place (Of_Tree, Place, State);
                           end if;
                        end;
                     end if;

                  when Syn.Increment | Syn.Decrement =>
                     Flow_Expression
                       (Of_Tree, Syn.Target_Of (Of_Tree, Item), Result,
                        State, Step);

                  when Syn.Discard | Syn.Call | Syn.Try_Expression
                     | Syn.If_Statement | Syn.Match_Statement
                     | Syn.Bare_Block | Syn.Loop_Statement
                     | Syn.While_Statement | Syn.For_Statement =>
                     Flow_Expression
                       (Of_Tree, Item, Result, State, Step);

                  when Syn.Break_Statement | Syn.Continue_Statement =>
                     Flow_Expression
                       (Of_Tree, Syn.Condition_Of (Of_Tree, Item), Result,
                        State, Step);
                     if Step.Falls_Through then
                        declare
                           Transfer_State : Assigned_Set := State;
                           Cleanup_Edges : Edge_Facts;
                           Value_Edges : Edge_Facts := Fallthrough_Edge;
                           Guarded : constant Boolean :=
                             Syn.Condition_Of (Of_Tree, Item) /= Syn.No_Node;
                           Target : constant Loop_Cleanup_Entry :=
                             Transfer_Loop (Of_Tree, Item);
                           First : constant Natural :=
                             Target.Cleanup_Base + 1;
                        begin
                           if Syn.Kind (Of_Tree, Item) = Syn.Break_Statement
                             and then Syn.Transfer_Value (Of_Tree, Item)
                               /= Syn.No_Node
                           then
                              Flow_Expression
                                (Of_Tree, Syn.Transfer_Value (Of_Tree, Item),
                                 Result, Transfer_State, Value_Edges);
                              Step.Returns := Step.Returns
                                or Value_Edges.Returns;
                           end if;

                           if Value_Edges.Falls_Through then
                              Flow_Cleanups
                                (Of_Tree, First, Cleanup.Structured_Transfer,
                                 Result, Transfer_State, Cleanup_Edges);
                              Step.Returns := Step.Returns
                                or Cleanup_Edges.Returns;
                           end if;
                           Step.Falls_Through := Guarded;
                        end;
                     end if;

                  when Syn.Defer_Statement | Syn.Undo_Statement =>
                     --  Registration reads no callee or argument.  The
                     --  syntactic call is checked against the DA state at
                     --  each edge on which it actually runs.
                     Cleanup_Stack.Append
                       (Cleanup_Entry'
                          (Kind   =>
                             (if Syn.Kind (Of_Tree, Item)
                                   = Syn.Undo_Statement
                              then Cleanup.Failure_Undo
                              else Cleanup.Deferred_Call),
                           Call   => Syn.Cleanup_Call (Of_Tree, Item),
                           Active => True));

                  when Syn.Fail_Statement =>
                     if Syn.Condition_Of (Of_Tree, Item) = Syn.No_Node then
                        Flow_Expression
                          (Of_Tree, Syn.Value_Of (Of_Tree, Item), Result,
                           State, Step);
                        if Step.Falls_Through then
                           declare
                              Failure_State : Assigned_Set := State;
                              Cleanup_Edges : Edge_Facts;
                           begin
                              Flow_Cleanups
                                (Of_Tree, 1, Cleanup.Failure_Propagation,
                                 Result, Failure_State, Cleanup_Edges);
                              Step.Returns := Step.Returns
                                or Cleanup_Edges.Returns
                                or Cleanup_Edges.Falls_Through;
                              Step.Falls_Through := False;
                           end;
                        end if;
                     else
                        Flow_Expression
                          (Of_Tree, Syn.Condition_Of (Of_Tree, Item), Result,
                           State, Step);
                        if Step.Falls_Through then
                           declare
                              Failing : Assigned_Set := State;
                              Error_Edges : Edge_Facts;
                           begin
                              Flow_Expression
                                (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                                 Result, Failing, Error_Edges);
                              if Error_Edges.Falls_Through then
                                 declare
                                    Cleanup_Edges : Edge_Facts;
                                 begin
                                    Flow_Cleanups
                                      (Of_Tree, 1,
                                       Cleanup.Failure_Propagation,
                                       Result, Failing, Cleanup_Edges);
                                    Error_Edges.Returns :=
                                      Error_Edges.Returns
                                      or Cleanup_Edges.Returns
                                      or Cleanup_Edges.Falls_Through;
                                 end;
                              end if;
                              Step.Returns := Step.Returns
                                or Error_Edges.Returns;
                              --  The guard's false edge continues with only
                              --  facts established while evaluating it.
                              Step.Falls_Through := True;
                           end;
                        end if;
                     end if;

                  when Syn.Return_Statement =>
                     Flow_Expression
                       (Of_Tree, Syn.Condition_Of (Of_Tree, Item), Result,
                        State, Step);

                     if Step.Falls_Through then
                        declare
                           Cleanup_Edges : Edge_Facts;
                           Guarded : constant Boolean :=
                             Syn.Condition_Of (Of_Tree, Item) /= Syn.No_Node;
                           Return_State : Assigned_Set := State;
                        begin
                           Flow_Cleanups
                             (Of_Tree, 1, Cleanup.Successful_Return,
                              Result, Return_State, Cleanup_Edges);

                           --  A cleanup may assign one or more named results
                           --  while evaluating an argument.  Check the
                           --  original return only after every normally
                           --  completing cleanup; a return from inside one
                           --  checked its own edge recursively.
                           if Cleanup_Edges.Falls_Through then
                              Require_Returns_Assigned
                                (Syn.Anchor (Of_Tree, Item), Return_State,
                                 "this returns and no path that arrives"
                                 & " assigned the return");
                              Require_Inout_Places_Live
                                (Syn.Anchor (Of_Tree, Item), Return_State);
                           end if;

                           Step.Returns := True;
                           Step.Falls_Through := Guarded;
                        end;
                     end if;

                  when others =>
                     null;
               end case;

               Edges.Returns := Edges.Returns or Step.Returns;
               Edges.Falls_Through := Step.Falls_Through;
            end;
         end loop;

         if Edges.Falls_Through
           and then Syn.Block_Value (Of_Tree, Block) /= Syn.No_Node
         then
            declare
               Value_Edges : Edge_Facts;
            begin
               Flow_Expression
                 (Of_Tree, Syn.Block_Value (Of_Tree, Block), Result,
                  State, Value_Edges);
               Edges.Returns := Edges.Returns or Value_Edges.Returns;
               Edges.Falls_Through := Value_Edges.Falls_Through;
            end;
         elsif Edges.Falls_Through and then Needs_Value then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Block),
               Message => "this control block can fall through without"
                          & " producing a value",
               Note    => "D124: an early return needs no joined value, but"
                          & " every fallthrough edge does",
               Related => Owner,
               Because => "this control expression needs a value",
               Into    => Found);
         end if;

         --  The optional final value has already been evaluated and, in
         --  lowering, stored in its consumer-owned join before cleanup.
         --  Only this lexical frame is left by ordinary fallthrough.  A
         --  return raised while one of its calls is evaluated recursively
         --  sees every still-active outer frame.
         if Edges.Falls_Through then
            declare
               Cleanup_Edges : Edge_Facts;
            begin
               Flow_Cleanups
                 (Of_Tree, Cleanup_Base + 1, Cleanup.Normal_Fallthrough,
                  Result, State, Cleanup_Edges);
               Edges.Returns := Edges.Returns or Cleanup_Edges.Returns;
               Edges.Falls_Through := Cleanup_Edges.Falls_Through;
            end;
         end if;

         while Natural (Cleanup_Stack.Length) > Cleanup_Base loop
            Cleanup_Stack.Delete_Last;
         end loop;
      end Flow_Block;

      Result_Id : constant Res.Declaration_Id :=
        (if Result_Node = Syn.No_Node
           or else Syn.Return_Count (Of_Tree, Function_Node) = 0
         then Res.No_Declaration
         else Declaration_At
           (Syn.Source_Of (Of_Tree),
            Syn.Nth_Return (Of_Tree, Function_Node, 1)));
      State : Assigned_Set := Nothing_Assigned;
      Edges : Edge_Facts;
   begin
      if Syn.Kind (Of_Tree, Body_Node) = Syn.Block then
         Flow_Block
           (Of_Tree, Body_Node, Result_Id,
            Syn.Origin (Of_Tree, Function_Node), State, Edges);
      else
         Flow_Expression
           (Of_Tree, Body_Node, Result_Id, State, Edges);
      end if;

      if Syn.Kind (Of_Tree, Body_Node) = Syn.Block
        and then Edges.Falls_Through
      then
         Require_Returns_Assigned
           (Syn.Anchor (Of_Tree, Function_Node), State,
            "this function can reach its `end` without assigning the"
            & " return");
         Require_Inout_Places_Live
           (Syn.Anchor (Of_Tree, Function_Node), State);
      end if;
   end Check_Function;

end Landin.Stages.Checking.Flow;
