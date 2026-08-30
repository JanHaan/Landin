with Ada.Containers.Vectors;

with Landin.Checking;
with Landin.Configuration;
with Landin.Cleanup;
with Landin.IR;
with Landin.IR.Verifier;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Types;

package body Landin.Stages.Lowering is

   package Syn renames Landin.Syntax;
   package Cleanup renames Landin.Cleanup;
   package Res renames Landin.Resolution;
   package Ty  renames Landin.Types;
   package IR  renames Landin.IR;

   use type IR.Block_Id;
   use type IR.Element_Total;
   use type IR.Field_Image_Form;
   use type IR.Field_Shape_Kind;
   use type IR.Atom_Set_Id;
   use type IR.Item_Id;
   use type IR.Nominal_Type_Id;
   use type IR.Slot_Id;
   use type IR.Signature_Id;
   use all type IR.Storage_Kind;
   use type IR.Part_Position;
   use type IR.Path_Step;
   use type IR.Path_Step_Array;
   use type IR.Value_Id;
   use type Landin.Checking.Atom_Set_Id;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Error_Set_Form;
   use type Landin.Checking.Field_Kind;
   use type Landin.Checking.Nominal_Type_Id;
   use type Landin.Checking.Routine_Instance_Id;
   use type Landin.Checking.Routine_Instance_State;
   use type Landin.Checking.Signature_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Res.Application_Class;
   use type Res.Argument_Role;
   use type Res.Declaration_Id;
   use type Res.Declaration_Sort;
   use type Res.Verdict;
   use type Ty.Folded;
   use type Ty.Magnitude;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Ty.Type_Kind;

   --  D118: the neutral subobject path one child identity spells.  The
   --  contextual forms below still reach exactly one depth, so this is
   --  where a depth-one identity becomes the run every operation carries;
   --  zero is no step at all, which is what a direct operation has.
   function Below (Child : Natural) return IR.Path_Step_Array
     is (if Child = 0 then IR.No_Path_Steps
         else [1 => (Field      => IR.Part_Position (Child),
                     Case_Index => 0)]);

   --  D119: descending one field into a place.  A place is a base field
   --  and D118's run below it, with base zero meaning the storage itself;
   --  selecting a field of the storage names that field and nothing under
   --  it, and selecting a field of anything deeper extends the run.
   --  D127: base zero says "the storage itself", and a run may start
   --  there -- an array element is reached by a step and not by a base.
   --  So a place is fresh only when it has neither, and descending into
   --  one that already has a run adds a step like any other.
   function Descended_Base
     (Base  : Natural;
      Steps : IR.Path_Step_Array;
      Field : Positive) return Natural
     is (if Base = 0 and then Steps'Length = 0 then Field else Base);

   function Descended_Steps
     (Base  : Natural;
      Steps : IR.Path_Step_Array;
      Field : Positive) return IR.Path_Step_Array
     is (if Base = 0 and then Steps'Length = 0 then IR.No_Path_Steps
         else Steps
              & IR.Path_Step_Array'
                  [1 => (Field      => IR.Part_Position (Field),
                         Case_Index => 0)]);

   --  D120: descending into one selected case's payload field.  It is a
   --  step like any other; naming the case is what says the run it indexes
   --  is a payload run and not an ordinary field run.  The base is always
   --  the variant part, so there is no base-zero form here.
   function Payload_Steps
     (Steps : IR.Path_Step_Array;
      Which : Positive;
      Field : Positive) return IR.Path_Step_Array
     is (Steps
         & IR.Path_Step_Array'
             [1 => (Field      => IR.Part_Position (Field),
                    Case_Index => Which)]);

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "lowering";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      Meanings : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Types : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);
      Unit : constant not null access IR.Unit :=
        Landin.Stages.Code (Context);
      Facts : constant Landin.Targets.Target_Facts :=
        Landin.Stages.Target (Context);
      Activity : constant not null access Landin.Configuration.Table :=
        Configurations (Context);

      function Tree_For (Id : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Landin.Syntax.Forest.Tree_Of
              (Landin.Stages.Trees (Context).all, Id));

      --  Resolution selects this view; the source's neutral application
      --  never becomes an alternate construction tree.
      function Is_Struct_Construction
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Is_Case_Construction
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Construction_Field_Count
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural;
      function Nth_Construction_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Index : Positive)
         return Syn.Node_Id;
      function Construction_Field_Value
        (Of_Tree : Syn.Tree; Field : Syn.Node_Id) return Syn.Node_Id;
      function Construction_Fill
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function Is_Struct_Construction
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) = Syn.Struct_Literal
            or else
              (Syn.Kind (Of_Tree, Node) = Syn.Labeled_Application
               and then Res.Class_Of (Meanings.all, Of_Tree, Node)
                          = Res.Type_Construction));

      function Is_Case_Construction
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) = Syn.Labeled_Application
            and then Res.Class_Of (Meanings.all, Of_Tree, Node)
                       = Res.Case_Construction);

      function Construction_Field_Count
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural is
         Count : Natural := 0;
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Struct_Literal then
            return Syn.Field_Value_Count (Of_Tree, Node);
         end if;
         for Index in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
            if Res.Role_Of
              (Meanings.all, Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Index))
                in Res.Field_Argument | Res.Payload_Argument
            then
               Count := Count + 1;
            end if;
         end loop;
         return Count;
      end Construction_Field_Count;

      function Nth_Construction_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Index : Positive)
         return Syn.Node_Id is
         Found : Natural := 0;
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Struct_Literal then
            return Syn.Nth_Field_Value (Of_Tree, Node, Index);
         end if;
         for At_Index in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
            declare
               Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, At_Index);
            begin
               if Res.Role_Of (Meanings.all, Of_Tree, Argument)
                    in Res.Field_Argument | Res.Payload_Argument
               then
                  Found := Found + 1;
                  if Found = Index then
                     return Argument;
                  end if;
               end if;
            end;
         end loop;
         raise Landin.Compiler_Defect;
      end Nth_Construction_Field;

      function Construction_Field_Value
        (Of_Tree : Syn.Tree; Field : Syn.Node_Id) return Syn.Node_Id
        is (if Syn.Kind (Of_Tree, Field) = Syn.Field_Value
            then Syn.Value_Of (Of_Tree, Field)
            else Syn.Expression_Projection (Of_Tree, Field));

      function Construction_Fill
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id is
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Struct_Literal then
            return Syn.Struct_Fill (Of_Tree, Node);
         end if;
         for Index in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
            declare
               Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, Index);
            begin
               if Res.Role_Of (Meanings.all, Of_Tree, Argument)
                    = Res.Fill_Argument
               then
                  return Syn.Expression_Projection (Of_Tree, Argument);
               end if;
            end;
         end loop;
         return Syn.No_Node;
      end Construction_Fill;

      --  Which declaration a declaring node is.  A scan, for the reason
      --  Landin.Stages.Checking gives for its own: Landin.Resolution
      --  publishes the other direction only, and the list is short.
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id;

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

         raise Landin.Compiler_Defect with
           "a declaring node the resolver never recorded";
      end Declaration_At;

      --  Where a declaration's value lives inside the item being filled.
      --  Dense and indexed by Declaration_Id, which is the bargain
      --  Landin.Checking already struck: no map anywhere.
      --  The resolver's count and not IR.Declaration_Limit, which asks a
      --  Unit that Prepare has not reached yet: this is elaborated before
      --  the statements below run.  Prepare takes the same number from
      --  the same table, so the two cannot disagree.
      subtype Declared is Positive range
        1 .. Positive'Max (1, Res.Declaration_Count (Meanings.all));

      type Slot_Map is array (Declared) of IR.Slot_Id;

      No_Slots : constant Slot_Map := [others => IR.No_Slot];

      Slots : Slot_Map := No_Slots;

      type Item_Map is array (Declared) of IR.Item_Id;
      Static_Function_Targets : Item_Map := [others => IR.No_Item];
      Finding_Static_Function : array (Declared) of Boolean :=
        [others => False];

      function Total_Syntax_Nodes return Natural;

      function Total_Syntax_Nodes return Natural is
         Total : Natural := 0;
      begin
         for Index in 1 .. Source_Count (Context) loop
            Total := Total + Syn.Node_Count
              (Tree_For (Nth_Source (Context, Index)).all);
         end loop;
         return Total;
      end Total_Syntax_Nodes;

      type Anonymous_Entry is record
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Node   : Syn.Node_Id             := Syn.No_Node;
         Item   : IR.Item_Id              := IR.No_Item;
      end record;

      Anonymous_Routines : array
        (1 .. Positive'Max (1, Total_Syntax_Nodes)) of Anonymous_Entry :=
          [others => (others => <>)];
      Anonymous_Count : Natural := 0;

      function Anonymous_Item
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Item_Id;

      function Anonymous_Item
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Item_Id
      is
      begin
         for Index in 1 .. Anonymous_Count loop
            if Anonymous_Routines (Index).Source = Syn.Source_Of (Of_Tree)
              and then Anonymous_Routines (Index).Node = Node
            then
               return Anonymous_Routines (Index).Item;
            end if;
         end loop;
         raise Landin.Compiler_Defect with
           "an anonymous function has no deterministic routine item";
      end Anonymous_Item;

      subtype Source_Atom_Set is Positive range
        1 .. Positive'Max
               (1, Landin.Checking.Atom_Set_Count (Types.all));
      type Atom_Set_Map is array (Source_Atom_Set) of IR.Atom_Set_Id;
      Atom_Sets : Atom_Set_Map := [others => IR.No_Atom_Set];

      function Atom_Set_For
        (Source : Landin.Checking.Atom_Set_Id) return IR.Atom_Set_Id;

      function Atom_Set_For
        (Source : Landin.Checking.Atom_Set_Id) return IR.Atom_Set_Id
      is
      begin
         if Source = Landin.Checking.No_Atom_Set then
            return IR.No_Atom_Set;
         end if;
         if Atom_Sets (Positive (Source)) = IR.No_Atom_Set then
            declare
               Count : constant Natural :=
                 Landin.Checking.Atom_Count (Types.all, Source);
               Members : IR.Atom_Array (1 .. Count);
            begin
               for Index in Members'Range loop
                  Members (Index) :=
                    Landin.Checking.Nth_Atom (Types.all, Source, Index);
               end loop;
               Atom_Sets (Positive (Source)) :=
                 IR.Add_Atom_Set (Unit.all, Members);
            end;
         end if;
         return Atom_Sets (Positive (Source));
      end Atom_Set_For;

      subtype Source_Nominal is Positive range
        1 .. Positive'Max
               (1, Landin.Checking.Nominal_Type_Count (Types.all));
      type Nominal_Map is array (Source_Nominal) of IR.Nominal_Type_Id;
      Nominals : Nominal_Map := [others => IR.No_Nominal_Type];

      function Nominal_For
        (Source : Landin.Checking.Nominal_Type_Id)
         return IR.Nominal_Type_Id;

      function Nominal_For
        (Source : Landin.Checking.Nominal_Type_Id)
         return IR.Nominal_Type_Id
      is
         Position : Positive;
      begin
         if Source = Landin.Checking.No_Nominal_Type then
            return IR.No_Nominal_Type;
         end if;
         Position := Landin.Checking.Nominal_Identities.Position
           (Types.all, Source);
         if Nominals (Position) = IR.No_Nominal_Type then
            raise Landin.Compiler_Defect with
              "a checker nominal identity was not mapped before lowering";
         end if;
         return Nominals (Position);
      end Nominal_For;

      subtype Source_Signature is Positive range
        1 .. Positive'Max
               (1, Landin.Checking.Signature_Count (Types.all));
      type Signature_Map is
        array (Source_Signature) of IR.Signature_Id;
      Signatures : Signature_Map := [others => IR.No_Signature];

      function Signature_For
        (Source : Landin.Checking.Signature_Id) return IR.Signature_Id;

      --  D78's arm bindings are aliases into the selected payload, not
      --  copied frame locals.  The declaration identity is arm-local; the
      --  source storage and three source-order identities remain target
      --  neutral until the backend derives an offset.
      --  D126: the variant part the arm matched may sit below the name,
      --  so the alias keeps the base field and the subject node the run
      --  down to it is read from.  A node and not a stored run, because a
      --  run is unconstrained and an alias lives inside one arm of one
      --  match in one tree.
      type Payload_Alias is record
         Active        : Boolean := False;
         Source        : IR.Storage;
         Field         : Natural := 0;
         Subject       : Syn.Node_Id := Syn.No_Node;
         Which         : Natural := 0;
         Payload_Field : Natural := 0;
      end record;

      type Alias_Map is array (Declared) of Payload_Alias;
      Aliases : Alias_Map := [others => (others => <>)];

      --  The item being filled, and the block instructions go into.
      --  Current is No_Block when the flow has been terminated and
      --  nothing further is reachable.  One block at a time: Enter allows
      --  one open block per item and refuses one that already holds
      --  something, so a block is filled once, in one go, and never
      --  returned to.
      Filling : IR.Item_Id  := IR.No_Item;
      Current : IR.Block_Id := IR.No_Block;
      Active_Result : IR.Slot_Id := IR.No_Slot;

      type Cleanup_Entry is record
         Kind   : Cleanup.Cleanup_Kind := Cleanup.Deferred_Call;
         Call   : Syn.Node_Id := Syn.No_Node;
         Scope  : Res.Scope_Id := Res.No_Scope;
         Active : Boolean := True;
      end record;

      package Cleanup_Entries is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Cleanup_Entry);

      package Cleanup_Indexes is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Positive);

      Cleanup_Stack : Cleanup_Entries.Vector;

      function Site_Of (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Landin.Provenance.Origin
        is (Syn.Origin (Of_Tree, Node));

      function Type_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Type_Kind
        is (Landin.Checking.Type_Of (Types.all, Of_Tree, Node));

      function Scalar_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Scalar_Name;

      function Signature_For
        (Source : Landin.Checking.Signature_Id) return IR.Signature_Id
      is
         Count : constant Natural :=
           Landin.Checking.Signature_Parameter_Count
             (Types.all, Source);
         Parts : IR.Signature_Part_Array (1 .. Count) :=
           [others => (others => <>)];
         Results : IR.Signature_Part_Array
           (1 .. Landin.Checking.Signature_Result_Count
                   (Types.all, Source)) := [others => (others => <>)];

         function Converted
           (Part : Landin.Checking.Signature_Part)
            return IR.Signature_Part
           is (Kind    =>
                 (if Part.Kind = Ty.Atom_Value then Ty.U32 else Part.Kind),
               Nominal => Nominal_For (Part.Nominal),
               Length  => IR.Element_Total (Part.Length),
               Element => Part.Element,
               Signature =>
                 (if Part.Kind = Ty.Function_Value
                  then Signature_For (Part.Signature)
                  else IR.No_Signature),
               Atoms =>
                 (if Part.Kind = Ty.Atom_Value
                  then Atom_Set_For (Part.Atoms)
                  else IR.No_Atom_Set));
      begin
         if Signatures (Positive (Source)) /= IR.No_Signature then
            return Signatures (Positive (Source));
         end if;
         if Landin.Checking.Signature_Error_Form (Types.all, Source)
              = Landin.Checking.Inferred
         then
            raise Landin.Compiler_Defect with
              "an unfinalized inferred error set reached lowering";
         end if;

         for Index in Parts'Range loop
            Parts (Index) :=
              Converted
                (Landin.Checking.Nth_Signature_Parameter
                   (Types.all, Source, Index));
         end loop;
         for Index in Results'Range loop
            Results (Index) :=
              Converted
                (Landin.Checking.Nth_Signature_Result
                   (Types.all, Source, Index));
         end loop;
         Signatures (Positive (Source)) :=
           IR.Add_Signature_With_Results
             (Unit.all, Parts, Results,
              Atom_Set_For
                (Landin.Checking.Signature_Errors (Types.all, Source)));
         return Signatures (Positive (Source));
      end Signature_For;

      --  [1820]'s operators onto Landin.IR's opcodes, one to one.  The
      --  two missing are the logical words: [0410] makes them
      --  short-circuit, so they are control flow and there is no opcode
      --  for this table to name.
      function Opcode_For (Of_Kind : Syn.Node_Kind) return IR.Opcode
        is (case Of_Kind is
               when Syn.Multiply          => IR.Multiply,
               when Syn.Divide            => IR.Divide,
               when Syn.Remainder         => IR.Remainder,
               when Syn.Wrapping_Multiply => IR.Wrapping_Multiply,
               when Syn.Add               => IR.Add,
               when Syn.Subtract          => IR.Subtract,
               when Syn.Wrapping_Add      => IR.Wrapping_Add,
               when Syn.Wrapping_Subtract => IR.Wrapping_Subtract,
               when Syn.Shift_Left        => IR.Shift_Left,
               when Syn.Shift_Right       => IR.Shift_Right,
               when Syn.Bitwise_And       => IR.Bitwise_And,
               when Syn.Bitwise_Xor       => IR.Bitwise_Xor,
               when Syn.Bitwise_Or        => IR.Bitwise_Or,
               when Syn.Equal_To          => IR.Equal_To,
               when Syn.Not_Equal_To      => IR.Not_Equal_To,
               when Syn.Less_Than         => IR.Less_Than,
               when Syn.Less_Or_Equal     => IR.Less_Or_Equal,
               when Syn.Greater_Than      => IR.Greater_Than,
               when Syn.Greater_Or_Equal  => IR.Greater_Or_Equal,
               when others                =>
                  raise Landin.Compiler_Defect with
                    "this operator has no opcode");

      procedure Impossible with No_Return;

      procedure Open (Block : IR.Block_Id);

      procedure Close_With_Jump
        (To : IR.Block_Id; Site : Landin.Provenance.Origin);

      function Fresh
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Block_Id;

      function Slot_For
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id) return IR.Slot_Id;

      --  D118: one selection chain [0420], read once.  Root is the name
      --  the chain started from -- the node itself when nothing was
      --  selected -- Base is the first selection's declaration-order
      --  field, and Steps is every selection after it in source order.
      --  Writing this walk out at each caller is what fixed the old depth
      --  at two.
      function Chain_Root
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function Chain_Depth
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural;

      function Chain_Base
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural;

      function Chain_Steps
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array;

      --  Every selection of the chain, including the first.  This is what
      --  a chain rooted at something that is itself already a part needs:
      --  D120's match alias names a payload, so the payload is the base
      --  and every selection below it is a step.
      function Chain_All_Steps
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array;

      --  Where a chain's root actually lives, and the place inside it the
      --  root already names.  An ordinary name is storage and names no
      --  part of it; D78's match alias names a selected payload of storage
      --  somewhere else, and D120 lets that payload be a struct whose
      --  fields the chain goes on to select.
      function Rooted_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Storage;

      function Rooted_Base
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural;

      function Rooted_Steps
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array;

      package Stored_Path_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => IR.Path_Step);

      type Stored_Place is record
         Place : IR.Storage := (others => <>);
         Base  : Natural := 0;
         Steps : Stored_Path_Vectors.Vector;
      end record;

      function Stored_Steps (Place : Stored_Place)
        return IR.Path_Step_Array;

      function Has_Computed_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      --  Evaluate every computed index in a storage chain from its root
      --  outward, bounds-check it immediately, and retain the reached
      --  aggregate element as an unspellable address slot.  Known indexes
      --  remain neutral identity steps, preserving D127's compact form.
      function Lower_Stored_Place
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return Stored_Place;

      function Addressed_Storage
        (Place : Stored_Place;
         Shape : IR.Field_Shape;
         Site  : Landin.Provenance.Origin) return IR.Storage;

      --  Whether that root is an aggregate payload alias, which is the one
      --  case where the three above do not answer what a slot would.
      function Roots_At_An_Aggregate_Alias
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      --  D121: the one index in a selection chain, when [0520]'s element
      --  is an ordinary struct and [0420] selected into it.  Chain_Above
      --  is everything that reaches the array; Chain_Below is every
      --  selection inside the element, which the backend adds after the
      --  scaled index.
      function Chain_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function Chain_Above
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function Chain_Below
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array;

      --  D75 uses D74's one variant carrier for both storage classes.
      --  Exactly one destination identity is supplied; payload leaves remain
      --  scalar or fixed-array shapes, and all offsets stay target-owned.
      procedure Add_Stored_Field
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Field : Positive;
         Datum : IR.Item_Id := IR.No_Item;
         Slot  : IR.Slot_Id := IR.No_Slot);

      function Lower_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      function Storage_For
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Storage;

      function Add_Value_Temporary
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Slot_Id;

      function Lower_Call
        (Of_Tree          : Syn.Tree;
         Node             : Syn.Node_Id;
         Scope            : Res.Scope_Id;
         Destination      : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Steps : IR.Path_Step_Array :=
           IR.No_Path_Steps;
         Propagate : Boolean := False) return IR.Value_Id;

      function Lower_Short_Circuit
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      function Lower_Control_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      procedure Lower_Stored_Expression
        (Of_Tree     : Syn.Tree;
         Node        : Syn.Node_Id;
         Scope       : Res.Scope_Id;
         Destination : IR.Slot_Id;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_Statements
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_If
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_Variant_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_Atom_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_Bare_Block
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Leave_With
        (Result : IR.Slot_Id; Site : Landin.Provenance.Origin);

      procedure Lower_Cleanup_Call
        (Of_Tree : Syn.Tree; Action : Cleanup_Entry);

      procedure Emit_Cleanups
        (Of_Tree : Syn.Tree;
         First   : Natural;
         On_Exit : Cleanup.Exit_Kind);

      procedure Leave_Through_Cleanups
        (Of_Tree : Syn.Tree;
         Result  : IR.Slot_Id;
         Site    : Landin.Provenance.Origin);

      procedure Fail_Through_Cleanups
        (Of_Tree : Syn.Tree;
         Error   : IR.Value_Id;
         Site    : Landin.Provenance.Origin);

      function Scalar_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Scalar_Name
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
      begin
         if Held = Ty.Function_Value then
            return Ty.Usize;
         elsif Held = Ty.Atom_Value then
            return Ty.U32;
         end if;
         if Held not in Ty.Scalar_Name then
            raise Landin.Compiler_Defect with
              "an expression reached the lowering with no scalar carrier";
         end if;

         return Held;
      end Scalar_At;

      procedure Impossible is
      begin
         raise Landin.Compiler_Defect with
           "a runtime address reached a scalar-only lowering path";
      end Impossible;

      procedure Open (Block : IR.Block_Id) is
      begin
         IR.Enter (Unit.all, Filling, Block);
         Current := Block;
      end Open;

      procedure Close_With_Jump
        (To : IR.Block_Id; Site : Landin.Provenance.Origin) is
      begin
         IR.Emit_Jump (Unit.all, Filling, To, Site);
         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;
      end Close_With_Jump;

      --  [1810]'s `return`, and the end of a body [0930].  The value is a
      --  load of the named return, because the return is a place the body
      --  assigned rather than an expression the exit carried.
      procedure Leave_With
        (Result : IR.Slot_Id; Site : Landin.Provenance.Origin)
      is
         Value : IR.Value_Id := IR.No_Value;
      begin
         if Result /= IR.No_Slot
           and then not IR.Is_Aggregate (Unit.all, Filling, Result)
           and then not IR.Is_Array (Unit.all, Filling, Result)
         then
            Value := IR.Emit_Load (Unit.all, Filling, Result, Site);
         end if;

         IR.Emit_Leave (Unit.all, Filling, Value, Site);
         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;
      end Leave_With;

      --  Evaluate and discard one registered call now.  Aggregate results
      --  still receive caller-owned shaped storage through completion; a
      --  scalar, function or no-value result needs no extra IR operation.
      procedure Lower_Cleanup_Call
        (Of_Tree : Syn.Tree; Action : Cleanup_Entry)
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Action.Call);
      begin
         if Held in Ty.Aggregate | Ty.Fixed_Array then
            declare
               Temporary : constant IR.Slot_Id :=
                 Add_Value_Temporary (Of_Tree, Action.Call);
               Ignored : constant IR.Value_Id :=
                 Lower_Call
                   (Of_Tree, Action.Call, Action.Scope,
                    Destination => Temporary);
            begin
               pragma Unreferenced (Ignored);
            end;
         else
            declare
               Ignored : constant IR.Value_Id :=
                 Lower_Call (Of_Tree, Action.Call, Action.Scope);
            begin
               pragma Unreferenced (Ignored);
            end;
         end if;
      end Lower_Cleanup_Call;

      procedure Emit_Cleanups
        (Of_Tree : Syn.Tree;
         First   : Natural;
         On_Exit : Cleanup.Exit_Kind)
      is
         Disabled : Cleanup_Indexes.Vector;
         Last : constant Natural := Natural (Cleanup_Stack.Length);
      begin
         if First = 0 or else First > Last then
            return;
         end if;

         for Position in reverse Positive (First) .. Positive (Last) loop
            exit when Current = IR.No_Block;

            declare
               Action : Cleanup_Entry := Cleanup_Stack (Position);
            begin
               if Action.Active
                 and then Cleanup.Applies (Action.Kind, On_Exit)
               then
                  --  Pop-before-run semantics: if evaluating this call
                  --  returns from inside a control-valued argument, that
                  --  return sees only the still-pending cleanup entries.
                  Action.Active := False;
                  Cleanup_Stack.Replace_Element (Position, Action);
                  Disabled.Append (Position);
                  Lower_Cleanup_Call (Of_Tree, Action);
               end if;
            end;
         end loop;

         --  Lowering subsequently visits sibling control edges over the
         --  same syntax.  Restore the compile-time entries after this edge;
         --  the generated runtime path has already consumed its calls.
         for Position of Disabled loop
            declare
               Action : Cleanup_Entry := Cleanup_Stack (Position);
            begin
               Action.Active := True;
               Cleanup_Stack.Replace_Element (Position, Action);
            end;
         end loop;
      end Emit_Cleanups;

      procedure Leave_Through_Cleanups
        (Of_Tree : Syn.Tree;
         Result  : IR.Slot_Id;
         Site    : Landin.Provenance.Origin) is
      begin
         Emit_Cleanups (Of_Tree, 1, Cleanup.Successful_Return);
         if Current /= IR.No_Block then
            Leave_With (Result, Site);
         end if;
      end Leave_Through_Cleanups;

      procedure Fail_Through_Cleanups
        (Of_Tree : Syn.Tree;
         Error   : IR.Value_Id;
         Site    : Landin.Provenance.Origin)
      is
         Saved : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site,
              Atoms => IR.Atom_Set_Of (Unit.all, Filling, Error));
      begin
         IR.Emit_Store (Unit.all, Filling, Saved, Error, Site);
         Emit_Cleanups (Of_Tree, 1, Cleanup.Failure_Propagation);
         if Current /= IR.No_Block then
            declare
               Carried : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Saved, Site);
            begin
               IR.Emit_Fail (Unit.all, Filling, Carried, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;
            end;
         end if;
      end Fail_Through_Cleanups;

      function Fresh
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Block_Id
        is (IR.Add_Block
              (Unit.all, Filling, Scope, Site_Of (Of_Tree, Node)));

      --  [1880]'s known index: a literal, or unary minus over one.  The
      --  checker has refused every such value outside the array; every
      --  other expression becomes [1950]'s checked runtime operand.
      function Is_Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Written : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
      begin
         return Syn.Kind (Of_Tree, Written) = Syn.Integer_Literal
           or else
             (Syn.Kind (Of_Tree, Written) = Syn.Negation
              and then Syn.Kind
                         (Of_Tree, Syn.Operand_Of (Of_Tree, Written))
                         = Syn.Integer_Literal);
      end Is_Constant_Index;

      --  What known brackets held, as the position it names.
      function Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Part_Position;

      function Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Part_Position
      is
         Written : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);

         --  `-0` is an index like any other: [1880] makes it known, its
         --  value is zero, and the checker refused every other negated
         --  one as outside the length.  So the minus is read through.
         Where : constant Syn.Node_Id :=
           (if Syn.Kind (Of_Tree, Written) = Syn.Negation
            then Syn.Operand_Of (Of_Tree, Written)
            else Written);
         Snap  : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Text  : constant String :=
           Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Where));
         Value      : Ty.Magnitude;
         Overflowed : Boolean;
      begin
         if Syn.Kind (Of_Tree, Where) /= Syn.Integer_Literal then
            raise Landin.Compiler_Defect with
              "an index the checker did not settle reached the lowering";
         end if;

         Ty.Evaluate (Text, Syn.Base (Of_Tree, Where), Value, Overflowed);

         --  One-based here, zero-based in the source: [0520] counts an
         --  array's elements from zero and every run in this compiler
         --  counts from one, and this is the one place the two meet.
         --  Zero-based in the source [0520] and one-based in every run
         --  this compiler keeps, and this is the one place the two meet.
         --  Added before converting, because a Part_Position starts at
         --  one and index zero is the first element.
         return IR.Part_Position (Value + 1);
      end Constant_Index;

      --  D127: a field operation names one part and then a run below it,
      --  so a run that starts at whole array storage gives its first step
      --  to the part -- which is what a known index of a scalar array has
      --  always been.  A whole-part operation instead keeps base zero,
      --  because zero is how it says "the storage itself".
      function Leaf_Base
        (Base : Natural; Steps : IR.Path_Step_Array) return IR.Part_Position
        is (if Base > 0 then IR.Part_Position (Base)
            else Steps (Steps'First).Field);

      function Leaf_Steps
        (Base : Natural; Steps : IR.Path_Step_Array)
         return IR.Path_Step_Array
        is (if Base > 0 then Steps
            else Steps (Steps'First + 1 .. Steps'Last));

      --  D127: a chain is a run of selectors, and a compile-time-known
      --  index is one of them -- an identity like a field.  A computed
      --  index is a value, so a chain stops at one and Chain_Index finds
      --  it separately.
      function Selects_One_Step
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            or else (Syn.Kind (Of_Tree, Node) = Syn.Element_Index
                     and then Is_Constant_Index (Of_Tree, Node)));

      --  Which part one step of a chain names: [0750]'s declaration order
      --  for a field, [0520]'s one-based position for a known index.
      function Step_Position
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural
        is (if Syn.Kind (Of_Tree, Node) = Syn.Element_Index
            then Natural (Constant_Index (Of_Tree, Node))
            else Landin.Checking.Field_Index (Types.all, Of_Tree, Node));


      --  One target-neutral shape per checker shape, built bottom up so
      --  that the run a shape names already exists when the shape does.
      --  D118's path is what reads these back and has no depth of its own,
      --  so neither does this: a child holding a child, and a variant
      --  payload that is one, are the same recursion.
      --
      --  The pair is split by what each can reach.  A leaf shape carries
      --  its own child body, so it is enough to recurse on; a variant
      --  part's cases are keyed by the declaration and field that wrote
      --  them, so only Neutral_Field can build one.
      function Neutral_Shape
        (Source : Landin.Checking.Field_Shape) return IR.Field_Shape;

      function Neutral_Field
        (Nominal : Landin.Checking.Nominal_Type_Id;
         Field   : Positive) return IR.Field_Shape;

      --  One whole declaration as a neutral shape: the run of its fields,
      --  appended before the shape that names it.
      function Neutral_Body
        (Nominal : Landin.Checking.Nominal_Type_Id) return IR.Field_Shape;

      --  One field of D128's anonymous result aggregate.  D131 gives a
      --  nominal aggregate the same one `usize` field plus its signature.
      function Neutral_Result_Part
        (Part : Landin.Checking.Signature_Part) return IR.Field_Shape;

      procedure Add_Result_Fields
        (Signature : Landin.Checking.Signature_Id;
         Item      : IR.Item_Id := IR.No_Item;
         Slot      : IR.Slot_Id := IR.No_Slot);

      --  D121: the element shape a whole array's storage repeats, whether
      --  that element is one of [1790]'s scalars or an ordinary struct.
      function Neutral_Element
        (Id : Res.Declaration_Id) return IR.Field_Shape;

      function Neutral_Element
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape;

      function Neutral_Value_Shape
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape;

      function Neutral_Shape
        (Source : Landin.Checking.Field_Shape) return IR.Field_Shape
      is
      begin
         case Source.Kind is
            when Landin.Checking.Scalar_Field =>
               return
                 (Kind      => IR.Scalar_Field_Shape,
                  Element   => Source.Element,
                  Length    => 1,
                  Signature =>
                    (if Source.Signature /= Landin.Checking.No_Signature
                     then Signature_For (Source.Signature)
                     else IR.No_Signature),
                  others    => <>);

            when Landin.Checking.Fixed_Array_Field =>
               --  D121: an ordinary-struct element is one run of exactly
               --  one shape, appended before the array shape names it.
               if Source.Nominal /= Landin.Checking.No_Nominal_Type then
                  declare
                     First : constant Natural :=
                       IR.Add_Shape_Run
                         (Unit.all,
                          [1 => Neutral_Body (Source.Nominal)]);
                  begin
                     return
                       (Kind           => IR.Array_Field_Shape,
                        Element        => Ty.Bool,
                        Length         => IR.Element_Total (Source.Length),
                        Cases          => 1,
                        Payloads_First => First,
                        Nominal        => Nominal_For (Source.Nominal),
                        others         => <>);
                  end;
               end if;
               return
                 (Kind    => IR.Array_Field_Shape,
                  Element => Source.Element,
                  Length  => IR.Element_Total (Source.Length),
                  others  => <>);

            when Landin.Checking.Aggregate_Field =>
               return Neutral_Body (Source.Nominal);

            when Landin.Checking.Variant_Field =>
               --  Lay_Out refuses a variant part inside a payload run, so
               --  nothing reaches one through a shape alone.
               raise Landin.Compiler_Defect with
                 "a variant part reached shape-only lowering";
         end case;
      end Neutral_Shape;

      function Neutral_Element
        (Id : Res.Declaration_Id) return IR.Field_Shape
      is
         Element : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Array_Element_Nominal (Types.all, Id);
      begin
         if Element /= Landin.Checking.No_Nominal_Type then
            return Neutral_Body (Element);
         end if;
         return
           (Kind    => IR.Scalar_Field_Shape,
            Element => Landin.Checking.Array_Element (Types.all, Id),
            Length  => 1,
            others  => <>);
      end Neutral_Element;

      function Neutral_Element
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape
      is
         Element : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Array_Element_Nominal
             (Types.all, Of_Tree, Node);
      begin
         if Element /= Landin.Checking.No_Nominal_Type then
            return Neutral_Body (Element);
         end if;
         return
           (Kind    => IR.Scalar_Field_Shape,
            Element =>
              Landin.Checking.Array_Element (Types.all, Of_Tree, Node),
            Length  => 1,
            others  => <>);
      end Neutral_Element;

      function Neutral_Value_Shape
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
      begin
         if Held = Ty.Aggregate then
            return Neutral_Body
              (Landin.Checking.Nominal_Of (Types.all, Of_Tree, Node));
         elsif Held = Ty.Fixed_Array then
            declare
               Element : constant IR.Field_Shape :=
                 Neutral_Element (Of_Tree, Node);
               First : constant Natural :=
                 (if Element.Kind = IR.Scalar_Field_Shape
                  then 0
                  else IR.Add_Shape_Run (Unit.all, [1 => Element]));
            begin
               return
                 (Kind           => IR.Array_Field_Shape,
                  Element        => Element.Element,
                  Length         => IR.Element_Total
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree, Node)),
                  Cases          => (if First = 0 then 0 else 1),
                  Payloads_First => First,
                  Nominal        => Element.Nominal,
                  others         => <>);
            end;
         end if;
         raise Landin.Compiler_Defect with
           "a scalar value was asked for a stored shape";
      end Neutral_Value_Shape;

      function Neutral_Body
        (Nominal : Landin.Checking.Nominal_Type_Id) return IR.Field_Shape
      is
         Count : constant Natural :=
           Landin.Checking.Layout_Field_Count (Types.all, Nominal);
         Parts : IR.Field_Shape_Array (1 .. Count) :=
           [others => (others => <>)];
         First : Natural;
      begin
         for Position in 1 .. Count loop
            Parts (Position) := Neutral_Field (Nominal, Position);
         end loop;
         First := IR.Add_Shape_Run (Unit.all, Parts);
         return
           (Kind           => IR.Aggregate_Field_Shape,
            Element        => Ty.Bool,
            Length         => 1,
            Cases          => Count,
            Payloads_First => First,
            Nominal        => Nominal_For (Nominal),
            others         => <>);
      end Neutral_Body;

      function Neutral_Result_Part
        (Part : Landin.Checking.Signature_Part) return IR.Field_Shape
      is
      begin
         case Part.Kind is
            when Ty.Scalar_Name =>
               return
                 (Kind => IR.Scalar_Field_Shape,
                  Element => Ty.Scalar_Name (Part.Kind),
                  Length => 1,
                  others => <>);
            when Ty.Function_Value =>
               return
                 (Kind => IR.Scalar_Field_Shape,
                  Element => Ty.Usize,
                  Length => 1,
                  Signature => Signature_For (Part.Signature),
                  others => <>);
            when Ty.Atom_Value =>
               return
                 (Kind => IR.Scalar_Field_Shape,
                  Element => Ty.U32,
                  Length => 1,
                  Atoms => Atom_Set_For (Part.Atoms),
                  others => <>);
            when Ty.Aggregate =>
               return Neutral_Body (Part.Nominal);
            when Ty.Fixed_Array =>
               if Part.Nominal /= Landin.Checking.No_Nominal_Type then
                  declare
                     First : constant Natural :=
                       IR.Add_Shape_Run
                         (Unit.all,
                          [1 => Neutral_Body (Part.Nominal)]);
                  begin
                     return
                       (Kind           => IR.Array_Field_Shape,
                        Element        => Ty.Bool,
                        Length         => IR.Element_Total (Part.Length),
                        Cases          => 1,
                        Payloads_First => First,
                        Nominal        => Nominal_For (Part.Nominal),
                        others         => <>);
                  end;
               end if;
               return
                 (Kind => IR.Array_Field_Shape,
                  Element => Part.Element,
                  Length => IR.Element_Total (Part.Length),
                  others => <>);
            when others =>
               raise Landin.Compiler_Defect with
                 "a non-value result part reached neutral lowering";
         end case;
      end Neutral_Result_Part;

      procedure Add_Result_Fields
        (Signature : Landin.Checking.Signature_Id;
         Item      : IR.Item_Id := IR.No_Item;
         Slot      : IR.Slot_Id := IR.No_Slot) is
      begin
         pragma Assert ((Item = IR.No_Item) /= (Slot = IR.No_Slot));
         for Index in
           1 .. Landin.Checking.Signature_Result_Count
                  (Types.all, Signature)
         loop
            declare
               Shape : constant IR.Field_Shape :=
                 Neutral_Result_Part
                   (Landin.Checking.Nth_Signature_Result
                      (Types.all, Signature, Index));
            begin
               if Item /= IR.No_Item then
                  IR.Add_Field (Unit.all, Item, Shape);
               else
                  IR.Add_Slot_Field (Unit.all, Filling, Slot, Shape);
               end if;
            end;
         end loop;
      end Add_Result_Fields;

      function Neutral_Field
        (Nominal : Landin.Checking.Nominal_Type_Id;
         Field   : Positive) return IR.Field_Shape
      is
         Source : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Field_Shape_Of (Types.all, Nominal, Field);
      begin
         if Source.Kind /= Landin.Checking.Variant_Field then
            return Neutral_Shape (Source);
         end if;

         declare
            Total : Natural := 0;
         begin
            for Which in 1 .. Source.Cases loop
               Total := Total
                 + Landin.Checking.Variant_Case_Field_Count
                     (Types.all, Nominal, Field, Which);
            end loop;

            declare
               Runs : IR.Case_Run_Array (1 .. Source.Cases) :=
                 [others => (others => 0)];
               Parts : IR.Field_Shape_Array (1 .. Total) :=
                 [others => (others => <>)];
               Next : Natural := 1;
               First : Natural;
               Where : Natural;
            begin
               for Which in 1 .. Source.Cases loop
                  declare
                     Count : constant Natural :=
                       Landin.Checking.Variant_Case_Field_Count
                         (Types.all, Nominal, Field, Which);
                  begin
                     Runs (Which) :=
                       (First => (if Count = 0 then 0 else Next),
                        Count => Count);
                     for Position in 1 .. Count loop
                        Parts (Next) := Neutral_Shape
                          (Landin.Checking.Nth_Variant_Case_Field
                             (Types.all, Nominal, Field, Which, Position));
                        Next := Next + 1;
                     end loop;
                  end;
               end loop;

               --  The payloads first, so a case run names where they
               --  actually landed rather than where they will.
               First := IR.Add_Shape_Run (Unit.all, Parts);
               for Which in Runs'Range loop
                  if Runs (Which).Count > 0 then
                     Runs (Which).First := First + Runs (Which).First - 1;
                  end if;
               end loop;
               Where := IR.Add_Case_Run (Unit.all, Runs);
               return
                 (Kind           => IR.Variant_Field_Shape,
                  Element        => Source.Element,
                  Length         => 1,
                  Cases          => Source.Cases,
                  Payloads_First => Where,
                  others         => <>);
            end;
         end;
      end Neutral_Field;

      function Chain_Root
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
      is
         Where : Syn.Node_Id := Node;
      begin
         while Selects_One_Step (Of_Tree, Where) loop
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Where;
      end Chain_Root;

      function Chain_Depth
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural
      is
         Where : Syn.Node_Id := Node;
         Total : Natural := 0;
      begin
         while Selects_One_Step (Of_Tree, Where) loop
            Total := Total + 1;
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Total;
      end Chain_Depth;

      function Chain_Base
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural
      is
         Where : Syn.Node_Id := Node;
         Base  : Natural := 0;
      begin
         while Selects_One_Step (Of_Tree, Where) loop
            --  D127: a run that starts at whole array storage has no base
            --  field, so its first known index is a step and not a base.
            Base :=
              (if Syn.Kind (Of_Tree, Where) = Syn.Element_Index then 0
               else Landin.Checking.Field_Index (Types.all, Of_Tree, Where));
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Base;
      end Chain_Base;

      function Chain_Steps
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array
      is
         Depth : constant Natural := Chain_Depth (Of_Tree, Node);
         --  A run that starts at whole array storage keeps every step,
         --  because base zero names no part.
         Kept : constant Natural :=
           (if Chain_Base (Of_Tree, Node) = 0 then Depth
            else Natural'Max (0, Depth - 1));
         Steps : IR.Path_Step_Array (1 .. Kept) :=
           [others => (others => <>)];
         Where : Syn.Node_Id := Node;
      begin
         for Step in reverse Steps'Range loop
            Steps (Step) :=
              (Field      =>
                 IR.Part_Position (Step_Position (Of_Tree, Where)),
               Case_Index => 0);
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Steps;
      end Chain_Steps;

      function Chain_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
      is
         Where : Syn.Node_Id := Node;
      begin
         while Selects_One_Step (Of_Tree, Where) loop
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
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array
      is
         Depth : Natural := 0;
         Where : Syn.Node_Id := Node;
      begin
         while Selects_One_Step (Of_Tree, Where) loop
            Depth := Depth + 1;
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;

         if Syn.Kind (Of_Tree, Where) /= Syn.Element_Index then
            return IR.No_Path_Steps;
         end if;

         declare
            Steps : IR.Path_Step_Array (1 .. Depth) :=
              [others => (others => <>)];
            Each : Syn.Node_Id := Node;
         begin
            for Step in reverse Steps'Range loop
               Steps (Step) :=
                 (Field      =>
                    IR.Part_Position (Step_Position (Of_Tree, Each)),
                  Case_Index => 0);
               Each := Syn.Target_Of (Of_Tree, Each);
            end loop;
            return Steps;
         end;
      end Chain_Below;

      function Chain_All_Steps
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array
      is
         Steps : IR.Path_Step_Array (1 .. Chain_Depth (Of_Tree, Node)) :=
           [others => (others => <>)];
         Where : Syn.Node_Id := Node;
      begin
         for Step in reverse Steps'Range loop
            Steps (Step) :=
              (Field      =>
                 IR.Part_Position (Step_Position (Of_Tree, Where)),
               Case_Index => 0);
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Steps;
      end Chain_All_Steps;

      function Roots_At_An_Aggregate_Alias
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Root : constant Syn.Node_Id := Chain_Root (Of_Tree, Node);
      begin
         if Syn.Kind (Of_Tree, Root) /= Syn.Name_Reference
           or else Res.Verdict_Of (Meanings.all, Of_Tree, Root) /= Res.Bound
         then
            return False;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Root);
         begin
            return Aliases (Declared (Means)).Active
              and then Landin.Checking.Type_Of (Types.all, Means)
                         = Ty.Aggregate;
         end;
      end Roots_At_An_Aggregate_Alias;

      function Rooted_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Storage
      is
         Root : constant Syn.Node_Id := Chain_Root (Of_Tree, Node);
      begin
         if Roots_At_An_Aggregate_Alias (Of_Tree, Node) then
            return Aliases
              (Declared (Res.Bound_To (Meanings.all, Of_Tree, Root))).Source;
         end if;
         return Storage_For (Of_Tree, Root);
      end Rooted_Storage;

      function Rooted_Base
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Natural
      is
         Root : constant Syn.Node_Id := Chain_Root (Of_Tree, Node);
      begin
         if Syn.Kind (Of_Tree, Root) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Root) = Res.Bound
           and then Aliases
             (Declared
                (Res.Bound_To (Meanings.all, Of_Tree, Root))).Active
         then
            return Aliases
              (Declared (Res.Bound_To (Meanings.all, Of_Tree, Root))).Field;
         end if;
         return Chain_Base (Of_Tree, Node);
      end Rooted_Base;

      --  The run that reaches the variant part an alias names, from its
      --  base field.  Empty when the part is the base field itself.
      --  D127: the alias recorded the promoted base, so the run it kept
      --  is the promoted one -- the same two answers, taken together.
      function Alias_Steps
        (Of_Tree : Syn.Tree; Alias : Payload_Alias)
         return IR.Path_Step_Array
        is (if Alias.Subject = Syn.No_Node then IR.No_Path_Steps
            else Leaf_Steps
              (Rooted_Base (Of_Tree, Alias.Subject),
               Rooted_Steps (Of_Tree, Alias.Subject)));

      function Rooted_Steps
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Path_Step_Array
      is
         Root : constant Syn.Node_Id := Chain_Root (Of_Tree, Node);
      begin
         if Roots_At_An_Aggregate_Alias (Of_Tree, Node) then
            declare
               Alias : Payload_Alias renames Aliases
                 (Declared (Res.Bound_To (Meanings.all, Of_Tree, Root)));
            begin
               if Alias.Which = 0 then
                  return Chain_All_Steps (Of_Tree, Node);
               end if;
               return Payload_Steps
                 (Alias_Steps (Of_Tree, Alias), Positive (Alias.Which),
                  Positive (Alias.Payload_Field))
                 & Chain_All_Steps (Of_Tree, Node);
            end;
         end if;
         if Syn.Kind (Of_Tree, Root) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Root) = Res.Bound
           and then Aliases
             (Declared
                (Res.Bound_To (Meanings.all, Of_Tree, Root))).Active
         then
            return Chain_All_Steps (Of_Tree, Node);
         end if;
         return Chain_Steps (Of_Tree, Node);
      end Rooted_Steps;

      function Stored_Steps (Place : Stored_Place)
        return IR.Path_Step_Array
      is
         Result : IR.Path_Step_Array
           (1 .. Natural (Place.Steps.Length)) := [others => (others => <>)];
      begin
         for Index in Result'Range loop
            Result (Index) := Place.Steps (Index);
         end loop;
         return Result;
      end Stored_Steps;

      function Has_Computed_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Where : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Of_Tree, Where)
           in Syn.Member_Selection | Syn.Element_Index
         loop
            if Syn.Kind (Of_Tree, Where) = Syn.Element_Index
              and then not Is_Constant_Index (Of_Tree, Where)
            then
               return True;
            end if;
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return False;
      end Has_Computed_Index;

      function Lower_Stored_Place
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return Stored_Place
      is
         Result : Stored_Place;
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Name_Reference =>
               Result.Place := Rooted_Storage (Of_Tree, Node);
               Result.Base := Rooted_Base (Of_Tree, Node);
               for Step of Rooted_Steps (Of_Tree, Node) loop
                  Result.Steps.Append (Step);
               end loop;
               return Result;

            when Syn.Member_Selection =>
               Result := Lower_Stored_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
               declare
                  Field : constant Positive := Positive
                    (Landin.Checking.Field_Index (Types.all, Of_Tree, Node));
               begin
                  if Result.Base = 0 and then Result.Steps.Is_Empty then
                     Result.Base := Field;
                  else
                     Result.Steps.Append
                       (IR.Path_Step'
                          (Field => IR.Part_Position (Field),
                           Case_Index => 0));
                  end if;
               end;
               return Result;

            when Syn.Element_Index =>
               Result := Lower_Stored_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
               if Is_Constant_Index (Of_Tree, Node) then
                  Result.Steps.Append
                    (IR.Path_Step'
                       (Field => Constant_Index (Of_Tree, Node),
                        Case_Index => 0));
                  return Result;
               end if;

               declare
                  Index : constant IR.Value_Id :=
                    Lower_Expression
                      (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
               begin
                  if Current = IR.No_Block then
                     return Result;
                  end if;
                  declare
                     Shape : constant IR.Field_Shape :=
                       Neutral_Element
                         (Of_Tree, Syn.Target_Of (Of_Tree, Node));
                     Address : constant IR.Value_Id :=
                       IR.Emit_Storage_Address
                         (Unit.all, Filling, Result.Place,
                          Site_Of (Of_Tree, Node),
                          Field  => Result.Base,
                          Nested => Stored_Steps (Result),
                          Index  => Index);
                     Slot : constant IR.Slot_Id :=
                       IR.Add_Address_Slot
                         (Unit.all, Filling, Shape,
                          Site_Of (Of_Tree, Node));
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Slot, Address,
                        Site_Of (Of_Tree, Node));
                     return
                       (Place => (Kind => IR.Runtime_Address,
                                  Address => Slot),
                        Base  => 0,
                        Steps => Stored_Path_Vectors.Empty_Vector);
                  end;
               end;

            when others =>
               raise Landin.Compiler_Defect with
                 "a contextual storage value has no rooted place";
         end case;
      end Lower_Stored_Place;

      function Addressed_Storage
        (Place : Stored_Place;
         Shape : IR.Field_Shape;
         Site  : Landin.Provenance.Origin) return IR.Storage
      is
      begin
         if Place.Place.Kind = IR.Runtime_Address
           and then Place.Base = 0
           and then Place.Steps.Is_Empty
         then
            return Place.Place;
         end if;

         declare
            Address : constant IR.Value_Id :=
              IR.Emit_Storage_Address
                (Unit.all, Filling, Place.Place, Site,
                 Field => Place.Base, Nested => Stored_Steps (Place));
            Slot : constant IR.Slot_Id :=
              IR.Add_Address_Slot (Unit.all, Filling, Shape, Site);
         begin
            IR.Emit_Store (Unit.all, Filling, Slot, Address, Site);
            return (Kind => IR.Runtime_Address, Address => Slot);
         end;
      end Addressed_Storage;

      procedure Add_Stored_Field
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Field : Positive;
         Datum : IR.Item_Id := IR.No_Item;
         Slot  : IR.Slot_Id := IR.No_Slot)
      is
         Shape : constant IR.Field_Shape := Neutral_Field (Wrote, Field);
      begin
         pragma Assert ((Datum = IR.No_Item) /= (Slot = IR.No_Slot));

         if Datum /= IR.No_Item then
            IR.Add_Field (Unit.all, Datum, Shape);
         else
            IR.Add_Slot_Field (Unit.all, Filling, Slot, Shape);
         end if;
      end Add_Stored_Field;

      --  A declaration's slot, made the first time it is wanted.  A local
      --  [1810], a parameter and the named return [1840] all become one;
      --  a module binding does not, and Lower_Expression sends those to
      --  Load_Datum instead.
      function Slot_For
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id) return IR.Slot_Id
      is
         Held : Ty.Type_Kind;
      begin
         if Slots (Positive (Id)) /= IR.No_Slot then
            return Slots (Positive (Id));
         end if;

         Held := Landin.Checking.Type_Of (Types.all, Id);

         --  D19's local array is one compact frame cell.  Its shape derives
         --  every known element operation without one IR field per element.
         if Held = Ty.Fixed_Array then
            Slots (Positive (Id)) :=
              IR.Add_Array_Slot
                (Unit.all, Filling,
                 Neutral_Element (Id),
                 IR.Element_Total
                   (Landin.Checking.Array_Length (Types.all, Id)),
                 Id,
                 Site_Of (Of_Tree, Node));
            return Slots (Positive (Id));
         end if;

         --  [0670]'s local: a cell holding a whole struct, carrying its
         --  fields' types the way an aggregate datum does.
         if Held = Ty.Aggregate then
            declare
               Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Id);
            begin
               Slots (Positive (Id)) :=
                 IR.Add_Aggregate_Slot
                   (Unit.all, Filling, Id, Site_Of (Of_Tree, Node),
                    Nominal_For (Nominal));

               if Landin.Checking.Result_Shape_Of (Types.all, Id)
                    /= Landin.Checking.No_Signature
               then
                  Add_Result_Fields
                    (Landin.Checking.Result_Shape_Of (Types.all, Id),
                     Slot => Slots (Positive (Id)));
               else
                  for Field in
                    1 .. Landin.Checking.Layout_Field_Count
                      (Types.all, Nominal)
                  loop
                     Add_Stored_Field
                       (Nominal, Field, Slot => Slots (Positive (Id)));
                  end loop;
               end if;

               return Slots (Positive (Id));
            end;
         end if;

         if Held not in Ty.Scalar_Name | Ty.Function_Value | Ty.Atom_Value
         then
            raise Landin.Compiler_Defect with
              "a declaration reached the lowering with no storable type";
         end if;

         Slots (Positive (Id)) :=
           IR.Add_Slot
             (Unit.all, Filling,
              (if Held = Ty.Function_Value then Ty.Usize
               elsif Held = Ty.Atom_Value then Ty.U32
               else Ty.Scalar_Name (Held)),
              Id, Site_Of (Of_Tree, Node),
              Signature =>
                (if Held = Ty.Function_Value
                 then Signature_For
                   (Landin.Checking.Signature_Of (Types.all, Id))
                 else IR.No_Signature),
              Atoms =>
                (if Held = Ty.Atom_Value
                 then Atom_Set_For
                   (Landin.Checking.Atom_Set_Of (Types.all, Id))
                 else IR.No_Atom_Set));
         return Slots (Positive (Id));
      end Slot_For;

      function Storage_For
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Storage
      is
         Means : constant Res.Declaration_Id :=
           Res.Bound_To (Meanings.all, Of_Tree, Node);
      begin
         if Aliases (Declared (Means)).Active then
            return Aliases (Declared (Means)).Source;
         end if;

         if Res.Sort_Of (Meanings.all, Means) = Res.Module_Binding then
            return
              (Kind => IR.Module_Datum,
               Datum => IR.Item_For (Unit.all, Means));
         end if;

         return
           (Kind => IR.Frame_Slot,
           Slot => Slot_For (Of_Tree, Node, Means));
      end Storage_For;

      --  A stored expression never becomes one host-sized IR value.  Its
      --  temporary therefore carries the checked target-neutral shape that
      --  every branch will fill, just as a declared caller-owned slot does.
      function Add_Value_Temporary
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Slot_Id
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Result : IR.Slot_Id;
      begin
         if Held = Ty.Fixed_Array then
            return IR.Add_Array_Slot
              (Unit.all, Filling,
               Neutral_Element (Of_Tree, Node),
               IR.Element_Total
                 (Landin.Checking.Array_Length (Types.all, Of_Tree, Node)),
               Res.No_Declaration, Site);
         end if;

         if Held = Ty.Aggregate then
            declare
               Wrote : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Of_Tree, Node);
               Shape : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Result_Shape_Of
                   (Types.all, Of_Tree, Node);
            begin
               Result := IR.Add_Aggregate_Slot
                 (Unit.all, Filling, Res.No_Declaration, Site,
                  Nominal_For (Wrote));
               if Shape /= Landin.Checking.No_Signature then
                  Add_Result_Fields (Shape, Slot => Result);
               else
                  pragma Assert
                    (Wrote /= Landin.Checking.No_Nominal_Type);
                  for Field in
                    1 .. Landin.Checking.Layout_Field_Count (Types.all, Wrote)
                  loop
                     Add_Stored_Field (Wrote, Field, Slot => Result);
                  end loop;
               end if;
               return Result;
            end;
         end if;

         raise Landin.Compiler_Defect with
           "a non-stored value requested a shaped temporary";
      end Add_Value_Temporary;

      ------------------------------------------------------------
      --  [0410]: `and` and `or` short-circuit, so they are blocks
      ------------------------------------------------------------

      --  The answer crosses a merge and Landin.IR has no phi, so it
      --  crosses through a slot -- exactly as a declared name does.  The
      --  slot carries no Declaration_Id, because no name declared it.
      function Lower_Short_Circuit
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Answer : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Ty.Bool, Res.No_Declaration, Site);
      begin
         declare
            Left : constant IR.Value_Id :=
              Lower_Expression
                (Of_Tree, Syn.Left_Of (Of_Tree, Node), Scope);
         begin
            if Current = IR.No_Block then
               return IR.No_Value;
            end if;
            pragma Assert (Left /= IR.No_Value);

            declare
               Rest : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Join : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
            begin
               IR.Emit_Store (Unit.all, Filling, Answer, Left, Site);

               --  `and` evaluates the right only when the left was true,
               --  `or` only when it was false.  One Branch says both.
               if Syn.Kind (Of_Tree, Node) = Syn.Logical_And then
                  IR.Emit_Branch
                    (Unit.all, Filling, Left, Rest, Join, Site);
               else
                  IR.Emit_Branch
                    (Unit.all, Filling, Left, Join, Rest, Site);
               end if;

               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Rest);

               declare
                  Right : constant IR.Value_Id :=
                    Lower_Expression
                      (Of_Tree, Syn.Right_Of (Of_Tree, Node), Scope);
               begin
                  if Current /= IR.No_Block then
                     pragma Assert (Right /= IR.No_Value);
                     IR.Emit_Store
                       (Unit.all, Filling, Answer, Right, Site);
                     Close_With_Jump (Join, Site);
                  end if;
               end;

               --  The short-circuited edge always reaches the join, even
               --  when evaluation of the right edge returned.
               Open (Join);
               return IR.Emit_Load (Unit.all, Filling, Answer, Site);
            end;
         end;
      end Lower_Short_Circuit;

      function Lower_Control_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
         Answer : IR.Slot_Id := IR.No_Slot;
      begin
         --  An all-return control has no fallthrough value to type or carry.
         --  The checker may therefore leave the control itself untyped even
         --  though its enclosing expression supplied a context.
         if Held in Ty.Scalar_Name | Ty.Atom_Value then
            Answer := IR.Add_Slot
              (Unit.all, Filling,
               (if Held = Ty.Atom_Value then Ty.U32
                else Ty.Scalar_Name (Held)),
               Res.No_Declaration, Site,
               Atoms =>
                 (if Held = Ty.Atom_Value
                  then Atom_Set_For
                    (Landin.Checking.Atom_Set_Of
                       (Types.all, Of_Tree, Node))
                  else IR.No_Atom_Set));
         elsif Held = Ty.Function_Value then
            Answer := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site,
               Signature => Signature_For
                 (Landin.Checking.Signature_Of
                    (Types.all, Of_Tree, Node)));
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.If_Statement =>
               Lower_If
                 (Of_Tree, Node, Scope, Active_Result, Answer);
            when Syn.Match_Statement =>
               Lower_Match
                 (Of_Tree, Node, Scope, Active_Result, Answer);
            when Syn.Bare_Block =>
               Lower_Bare_Block
                 (Of_Tree, Node, Scope, Active_Result, Answer);
            when others =>
               raise Landin.Compiler_Defect with
                 "a non-control expression reached control lowering";
         end case;

         if Current = IR.No_Block then
            return IR.No_Value;
         end if;

         pragma Assert (Answer /= IR.No_Slot);
         return IR.Emit_Load (Unit.all, Filling, Answer, Site);
      end Lower_Control_Expression;

      --  Calls and control expressions both fill storage owned by their
      --  enclosing operation.  Keeping that destination explicit avoids an
      --  aggregate pseudo-value and leaves all layout arithmetic to targets.
      procedure Lower_Stored_Expression
        (Of_Tree     : Syn.Tree;
         Node        : Syn.Node_Id;
         Scope       : Res.Scope_Id;
         Destination : IR.Slot_Id;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Ignored : IR.Value_Id;
         pragma Unreferenced (Ignored);
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Call | Syn.Labeled_Application =>
               Ignored := Lower_Call
                 (Of_Tree, Node, Scope, Destination => Destination,
                  Destination_Field => Destination_Field,
                  Destination_Steps => Destination_Path);
            when Syn.Try_Expression =>
               Ignored := Lower_Call
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope,
                  Destination => Destination,
                  Destination_Field => Destination_Field,
                  Destination_Steps => Destination_Path,
                  Propagate => True);
            when Syn.If_Statement =>
               Lower_If
                 (Of_Tree, Node, Scope, Active_Result, Destination,
                  Destination_Field, Destination_Path);
            when Syn.Match_Statement =>
               Lower_Match
                 (Of_Tree, Node, Scope, Active_Result, Destination,
                  Destination_Field, Destination_Path);
            when Syn.Bare_Block =>
               Lower_Bare_Block
                 (Of_Tree, Node, Scope, Active_Result, Destination,
                  Destination_Field, Destination_Path);
            when others =>
               raise Landin.Compiler_Defect with
                 "an expression cannot fill caller-owned storage";
         end case;
      end Lower_Stored_Expression;

      ------------------------------------------------------------
      --  [1920]: a call
      ------------------------------------------------------------

      function Lower_Call
        (Of_Tree          : Syn.Tree;
         Node             : Syn.Node_Id;
         Scope            : Res.Scope_Id;
         Destination      : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Steps : IR.Path_Step_Array :=
           IR.No_Path_Steps;
         Propagate : Boolean := False) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Node);
         Named : constant Boolean :=
           Syn.Kind (Of_Tree, Callee) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Callee)
             = Res.Bound;
         Means : constant Res.Declaration_Id :=
           (if Named
            then Res.Bound_To (Meanings.all, Of_Tree, Callee)
            else Res.No_Declaration);
         Direct : constant Boolean :=
           Named
           and then Res.Sort_Of (Meanings.all, Means)
             = Res.Module_Function;
         Generic_Target : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Target_Of
             (Types.all, Of_Tree, Node);
         Source_Signature : constant Landin.Checking.Signature_Id :=
           (if Generic_Target /= Landin.Checking.No_Routine_Instance
            then Landin.Checking.Routine_Signature_Of
              (Types.all, Generic_Target)
            elsif Named
            then Landin.Checking.Signature_Of (Types.all, Means)
            else Landin.Checking.Signature_Of
              (Types.all, Of_Tree, Callee));
         Signature : constant IR.Signature_Id :=
           (if Source_Signature = Landin.Checking.No_Signature
            then IR.No_Signature
            else Signature_For (Source_Signature));
         Indirect : constant Boolean := not Direct;
         Target : constant IR.Item_Id :=
           (if Indirect then IR.No_Item
            elsif Generic_Target /= Landin.Checking.No_Routine_Instance
            then IR.Item_For_Instance
              (Unit.all,
               Landin.Checking.Routine_Identities.Position
                 (Types.all, Generic_Target))
            else IR.Item_For (Unit.all, Means));
         Count : constant Natural := Syn.Argument_Count (Of_Tree, Node);
         Returns_Stored : constant Boolean :=
           Type_At (Of_Tree, Node)
             in Ty.Aggregate | Ty.Fixed_Array;
         Given : array (1 .. Positive'Max (1, Count)) of IR.Value_Id :=
           [others => IR.No_Value];
         Saved : array (1 .. Positive'Max (1, Count)) of IR.Slot_Id :=
           [others => IR.No_Slot];
         Hidden : IR.Value_Id := IR.No_Value;
         Callee_Saved : IR.Slot_Id := IR.No_Slot;
         Callee_Value : IR.Value_Id := IR.No_Value;
         Error_Set : constant IR.Atom_Set_Id :=
           (if Signature = IR.No_Signature
            then IR.No_Atom_Set
            else IR.Signature_Errors (Unit.all, Signature));
         Failure_Slot : IR.Slot_Id := IR.No_Slot;
         Success_Slot : IR.Slot_Id := IR.No_Slot;
         Made : IR.Value_Id;
      begin
         if Source_Signature = Landin.Checking.No_Signature
           or else Signature = IR.No_Signature
         then
            raise Landin.Compiler_Defect with
              "a call reached lowering without a checked signature";
         end if;

         if Error_Set /= IR.No_Atom_Set then
            Failure_Slot := IR.Add_Slot
              (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site,
               Atoms => Error_Set);
            if Type_At (Of_Tree, Node)
                 in Ty.Scalar_Name | Ty.Function_Value | Ty.Atom_Value
            then
               Success_Slot := IR.Add_Slot
                 (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                  Res.No_Declaration, Site,
                  Signature =>
                    (if Type_At (Of_Tree, Node) = Ty.Function_Value
                     then Signature_For
                       (Landin.Checking.Signature_Of
                          (Types.all, Of_Tree, Node))
                     else IR.No_Signature),
                  Atoms =>
                    (if Type_At (Of_Tree, Node) = Ty.Atom_Value
                     then Atom_Set_For
                       (Landin.Checking.Atom_Set_Of
                          (Types.all, Of_Tree, Node))
                     else IR.No_Atom_Set));
            end if;
         end if;
         if Indirect then
            Callee_Saved := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site,
               Signature => Signature);
            declare
               Value : constant IR.Value_Id :=
                 Lower_Expression (Of_Tree, Callee, Scope);
            begin
               if Current = IR.No_Block then
                  return IR.No_Value;
               end if;
               IR.Emit_Store
                 (Unit.all, Filling, Callee_Saved, Value, Site);
            end;
         end if;

         --  [0410] fixes argument evaluation left to right.  Every argument
         --  with another after it crosses through a slot before that later
         --  expression runs: a short circuit there can change blocks, and
         --  operands are block-local.  The last argument is already in the
         --  block where the call will be emitted.
         for Which in 1 .. Count loop
            declare
               Raw_Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, Which);
               Argument : constant Syn.Node_Id :=
                 (if Syn.Kind (Of_Tree, Raw_Argument) = Syn.Call_Argument
                  then Syn.Expression_Projection (Of_Tree, Raw_Argument)
                  else Raw_Argument);
            begin
               if Type_At (Of_Tree, Argument)
                    in Ty.Aggregate | Ty.Fixed_Array
               then
                  if Syn.Kind (Of_Tree, Argument)
                       in Syn.Call | Syn.Try_Expression | Syn.If_Statement
                          | Syn.Match_Statement | Syn.Bare_Block
                  then
                     declare
                        Temporary : constant IR.Slot_Id :=
                          Add_Value_Temporary (Of_Tree, Argument);
                     begin
                        Lower_Stored_Expression
                          (Of_Tree, Argument, Scope, Temporary);
                        if Current /= IR.No_Block then
                           Given (Which) := IR.Emit_Storage_Address
                             (Unit.all, Filling,
                              (Kind => IR.Frame_Slot, Slot => Temporary),
                              Site_Of (Of_Tree, Argument));
                        end if;
                     end;
                  elsif Syn.Kind (Of_Tree, Argument)
                          = Syn.Zeroed_Literal
                  then
                     declare
                        Parameter : constant
                          Landin.Checking.Signature_Part :=
                            Landin.Checking.Nth_Signature_Parameter
                              (Types.all, Source_Signature, Which);
                        Temporary : IR.Slot_Id;
                     begin
                        if Type_At (Of_Tree, Argument) = Ty.Aggregate then
                           Temporary := IR.Add_Aggregate_Slot
                             (Unit.all, Filling, Res.No_Declaration,
                              Site_Of (Of_Tree, Argument),
                              Nominal_For (Parameter.Nominal));
                           for Field in
                             1 .. Landin.Checking.Layout_Field_Count
                                    (Types.all, Parameter.Nominal)
                           loop
                              Add_Stored_Field
                                (Parameter.Nominal, Field,
                                 Slot => Temporary);
                           end loop;
                        else
                           Temporary := IR.Add_Array_Slot
                             (Unit.all, Filling,
                              Parameter.Element,
                              IR.Element_Total (Parameter.Length),
                              Res.No_Declaration,
                              Site_Of (Of_Tree, Argument));
                        end if;

                        IR.Emit_Array_Clear
                          (Unit.all, Filling,
                           (Kind => IR.Frame_Slot, Slot => Temporary),
                           Site_Of (Of_Tree, Argument));
                        Given (Which) := IR.Emit_Storage_Address
                          (Unit.all, Filling,
                           (Kind => IR.Frame_Slot, Slot => Temporary),
                           Site_Of (Of_Tree, Argument));
                     end;
                  elsif Is_Struct_Construction (Of_Tree, Argument) then
                     declare
                        Parameter : constant
                          Landin.Checking.Signature_Part :=
                            Landin.Checking.Nth_Signature_Parameter
                              (Types.all, Source_Signature, Which);
                        Id : constant Landin.Checking.Nominal_Type_Id :=
                          Parameter.Nominal;
                        Count : constant Natural :=
                          Landin.Checking.Layout_Field_Count (Types.all, Id);
                        type Seen_Array is
                          array (Positive range <>) of Boolean;
                        Seen : Seen_Array (1 .. Count) := [others => False];
                        Temporary : constant IR.Slot_Id :=
                          IR.Add_Aggregate_Slot
                            (Unit.all, Filling, Res.No_Declaration,
                             Site_Of (Of_Tree, Argument), Nominal_For (Id));

                        procedure Store_Child_Scalar
                          (Field       : Positive;
                           Child_Field : Positive;
                           Held        : IR.Value_Id;
                           At_Site     : Landin.Provenance.Origin);

                        procedure Store_Child_Scalar
                          (Field       : Positive;
                           Child_Field : Positive;
                           Held        : IR.Value_Id;
                           At_Site     : Landin.Provenance.Origin) is
                        begin
                           IR.Emit_Store_Slot_Field
                             (Unit.all, Filling, Temporary,
                              IR.Part_Position (Field), Held, At_Site,
                              Nested => Below (Child_Field));
                        end Store_Child_Scalar;

                        procedure Write_Array_Field
                          (Field         : Positive;
                           Value         : Syn.Node_Id;
                           Path          : IR.Path_Step_Array :=
                             IR.No_Path_Steps;
                           Variant_Case  : Natural := 0;
                           Payload_Field : Natural := 0);

                        procedure Write_Array_Field
                          (Field         : Positive;
                           Value         : Syn.Node_Id;
                           Path          : IR.Path_Step_Array :=
                             IR.No_Path_Steps;
                           Variant_Case  : Natural := 0;
                           Payload_Field : Natural := 0)
                        is
                           Kind : constant Syn.Node_Kind :=
                             Syn.Kind (Of_Tree, Value);
                           Prefix : constant Natural :=
                             (if Kind in Syn.Array_Literal
                                          | Syn.Mixed_Array_Repetition
                              then Syn.Element_Count (Of_Tree, Value)
                              else 0);
                        begin
                           for Position in 1 .. Prefix loop
                              declare
                                 Element : constant Syn.Node_Id :=
                                   Syn.Nth_Element
                                     (Of_Tree, Value, Position);
                                 Held : constant IR.Value_Id :=
                                   Lower_Expression
                                     (Of_Tree, Element, Scope);
                              begin
                                 if Current = IR.No_Block then
                                    return;
                                 end if;
                                 declare
                                    Index : constant IR.Value_Id :=
                                      IR.Emit_Number
                                        (Unit.all, Filling, Ty.Usize,
                                         Ty.Magnitude (Position - 1), False,
                                         Site_Of (Of_Tree, Element));
                                 begin
                                    IR.Emit_Store_Slot_Element
                                      (Unit.all, Filling, Temporary, Index,
                                       Held, Site_Of (Of_Tree, Element),
                                       Field => Field,
                                       Nested => Path,
                                       Variant_Case => Variant_Case,
                                       Variant_Payload_Field => Payload_Field);
                                 end;
                              end;
                           end loop;

                           if Kind in Syn.Array_Repetition
                                      | Syn.Mixed_Array_Repetition
                           then
                              declare
                                 Repeated : constant Syn.Node_Id :=
                                   Syn.Repeated_Element (Of_Tree, Value);
                                 Held : constant IR.Value_Id :=
                                   Lower_Expression
                                     (Of_Tree, Repeated, Scope);
                              begin
                                 if Current = IR.No_Block then
                                    return;
                                 end if;
                                 IR.Emit_Array_Fill
                                   (Unit.all, Filling,
                                    (Kind => IR.Frame_Slot,
                                     Slot => Temporary),
                                    IR.Part_Position (Prefix + 1),
                                    Held,
                                    Site_Of (Of_Tree, Repeated),
                                    Field => Field,
                                    Nested => Path,
                                    Variant_Case => Variant_Case,
                                    Variant_Payload_Field => Payload_Field);
                              end;
                           elsif Kind = Syn.Zeroed_Literal then
                              if Payload_Field = 0 then
                                 IR.Emit_Array_Clear
                                   (Unit.all, Filling,
                                    (Kind => IR.Frame_Slot,
                                     Slot => Temporary),
                                    Site_Of (Of_Tree, Value), Field => Field,
                                    Nested => Path);
                              end if;
                           elsif Kind not in Syn.Array_Literal then
                              declare
                                 Source_Place : constant IR.Storage :=
                                   Rooted_Storage (Of_Tree, Value);
                                 Source_Field : constant Natural :=
                                   Rooted_Base (Of_Tree, Value);
                                 Source_Steps : constant IR.Path_Step_Array :=
                                   Rooted_Steps (Of_Tree, Value);
                              begin
                                 IR.Emit_Array_Copy
                                   (Unit.all, Filling,
                                    Source => Source_Place,
                                    Destination =>
                                      (Kind => IR.Frame_Slot,
                                       Slot => Temporary),
                                    Site => Site_Of (Of_Tree, Value),
                                    Source_Field => Source_Field,
                                    Source_Nested => Source_Steps,
                                    Destination_Field => Field,
                                    Destination_Nested => Path,
                                    Destination_Variant_Case => Variant_Case,
                                    Destination_Variant_Payload_Field =>
                                      Payload_Field);
                              end;
                           end if;
                        end Write_Array_Field;

                        procedure Write_Variant_Field
                          (Field : Positive; Value : Syn.Node_Id);

                        procedure Write_Variant_Field
                          (Field : Positive; Value : Syn.Node_Id)
                        is
                           Variant_Case : constant Positive := Positive
                             (Landin.Checking.Field_Index
                                (Types.all, Of_Tree, Value));
                        begin
                           IR.Emit_Variant_Select
                             (Unit.all, Filling,
                              (Kind => IR.Frame_Slot, Slot => Temporary),
                              Field, Variant_Case,
                              Site_Of (Of_Tree, Value));

                           if not Is_Case_Construction (Of_Tree, Value) then
                              return;
                           end if;

                           for Position in
                             1 .. Construction_Field_Count (Of_Tree, Value)
                           loop
                              declare
                                 Label : constant Syn.Node_Id :=
                                   Nth_Construction_Field
                                     (Of_Tree, Value, Position);
                                 Payload_Field : constant Positive := Positive
                                   (Landin.Checking.Field_Index
                                      (Types.all, Of_Tree, Label));
                                 Shape : constant
                                   Landin.Checking.Field_Shape :=
                                     Landin.Checking.Nth_Variant_Case_Field
                                       (Types.all, Id, Field, Variant_Case,
                                        Payload_Field);
                                 Payload : constant Syn.Node_Id :=
                                   Construction_Field_Value
                                     (Of_Tree, Label);
                              begin
                                 case Shape.Kind is
                                    when Landin.Checking.Scalar_Field =>
                                       declare
                                          Held : constant IR.Value_Id :=
                                            Lower_Expression
                                              (Of_Tree, Payload, Scope);
                                       begin
                                          if Current /= IR.No_Block then
                                             IR.Emit_Variant_Field_Store
                                               (Unit.all, Filling,
                                                (Kind => IR.Frame_Slot,
                                                 Slot => Temporary),
                                                Field, Variant_Case,
                                                Payload_Field, Held,
                                                Site_Of (Of_Tree, Label));
                                          end if;
                                       end;
                                    when Landin.Checking.Fixed_Array_Field =>
                                       Write_Array_Field
                                         (Field, Payload,
                                          Variant_Case => Variant_Case,
                                          Payload_Field => Payload_Field);
                                    when others =>
                                       raise Landin.Compiler_Defect;
                                 end case;
                                 exit when Current = IR.No_Block;
                              end;
                           end loop;
                        end Write_Variant_Field;
                     begin
                        for Field in 1 .. Count loop
                           Add_Stored_Field
                             (Id, Field, Slot => Temporary);
                        end loop;

                        for Position in
                          1 .. Construction_Field_Count (Of_Tree, Argument)
                        loop
                           declare
                              Label : constant Syn.Node_Id :=
                                Nth_Construction_Field
                                  (Of_Tree, Argument, Position);
                              Field : constant Positive := Positive
                                (Landin.Checking.Field_Index
                                   (Types.all, Of_Tree, Label));
                              Value : constant Syn.Node_Id :=
                                Construction_Field_Value (Of_Tree, Label);
                           begin
                              Seen (Field) := True;
                              case Landin.Checking.Field_Kind_Of
                                (Types.all, Id, Field)
                              is
                                 when Landin.Checking.Scalar_Field =>
                                    declare
                                       Held : constant IR.Value_Id :=
                                         Lower_Expression
                                           (Of_Tree, Value, Scope);
                                    begin
                                       if Current /= IR.No_Block then
                                          IR.Emit_Store_Slot_Field
                                            (Unit.all, Filling, Temporary,
                                             IR.Part_Position (Field), Held,
                                             Site_Of (Of_Tree, Label));
                                       end if;
                                    end;
                                 when Landin.Checking.Fixed_Array_Field =>
                                    Write_Array_Field (Field, Value);
                                 when Landin.Checking.Variant_Field =>
                                    Write_Variant_Field (Field, Value);
                                 when Landin.Checking.Aggregate_Field =>
                                    declare
                                       Child : constant
                                         Landin.Checking.Nominal_Type_Id :=
                                         Landin.Checking.Field_Shape_Of
                                           (Types.all, Id, Field)
                                             .Nominal;
                                       Destination : constant IR.Storage :=
                                         (Kind => IR.Frame_Slot,
                                          Slot => Temporary);
                                    begin
                                       if Is_Struct_Construction
                                         (Of_Tree, Value)
                                       then
                                          --  The child begins as its padded
                                          --  zero image; labels then commit
                                          --  in source order.
                                          IR.Emit_Array_Clear
                                            (Unit.all, Filling, Destination,
                                             Site_Of (Of_Tree, Value),
                                             Field => Field);
                                          for Child_Position in
                                            1 .. Construction_Field_Count
                                                   (Of_Tree, Value)
                                          loop
                                             declare
                                                Label : constant Syn.Node_Id :=
                                                  Nth_Construction_Field
                                                    (Of_Tree, Value,
                                                     Child_Position);
                                                Child_Field : constant
                                                  Positive := Positive
                                                    (Landin.Checking
                                                       .Field_Index
                                                         (Types.all, Of_Tree,
                                                          Label));
                                                Child_Value : constant
                                                  Syn.Node_Id :=
                                                    Construction_Field_Value
                                                      (Of_Tree, Label);
                                             begin
                                                case Landin.Checking
                                                  .Field_Kind_Of
                                                    (Types.all, Child,
                                                     Child_Field)
                                                is
                                                   when Landin.Checking
                                                     .Scalar_Field =>
                                                      declare
                                                         Held : constant
                                                           IR.Value_Id :=
                                                             Lower_Expression
                                                               (Of_Tree,
                                                                Child_Value,
                                                                Scope);
                                                      begin
                                                         if Current /=
                                                           IR.No_Block
                                                         then
                                                            Store_Child_Scalar
                                                              (Field,
                                                               Child_Field,
                                                               Held,
                                                               Site_Of
                                                                 (Of_Tree,
                                                                  Label));
                                                         end if;
                                                      end;
                                                   when Landin.Checking
                                                     .Fixed_Array_Field =>
                                                      Write_Array_Field
                                                        (Field, Child_Value,
                                                         Path =>
                                                           Below
                                                             (Child_Field));
                                                   when others =>
                                                      raise
                                                        Landin.Compiler_Defect;
                                                end case;
                                                exit when
                                                  Current = IR.No_Block;
                                             end;
                                          end loop;
                                       elsif Syn.Kind (Of_Tree, Value)
                                               = Syn.Zeroed_Literal
                                       then
                                          IR.Emit_Array_Clear
                                            (Unit.all, Filling, Destination,
                                             Site_Of (Of_Tree, Value),
                                             Field => Field);
                                       else
                                          declare
                                             Source_Child : constant Boolean :=
                                               Syn.Kind (Of_Tree, Value)
                                                 = Syn.Member_Selection;
                                             Source_Named : constant
                                               Syn.Node_Id :=
                                                 (if Source_Child
                                                  then Syn.Target_Of
                                                    (Of_Tree, Value)
                                                  else Value);
                                             Source_Parent : constant
                                               Natural :=
                                                 (if Source_Child
                                                then Landin.Checking
                                                  .Field_Index
                                                    (Types.all, Of_Tree,
                                                     Value)
                                                else 0);
                                             Source : constant IR.Storage :=
                                               Storage_For
                                                 (Of_Tree, Source_Named);
                                          begin
                                             for Child_Field in
                                               1 .. Landin.Checking
                                                      .Layout_Field_Count
                                                        (Types.all, Child)
                                             loop
                                                case Landin.Checking
                                                  .Field_Kind_Of
                                                    (Types.all, Child,
                                                     Child_Field)
                                                is
                                                   when Landin.Checking
                                                     .Scalar_Field =>
                                                      declare
                                                         Shape : constant
                                                           Landin.Checking
                                                             .Field_Shape :=
                                                           Landin.Checking
                                                             .Field_Shape_Of
                                                               (Types.all,
                                                                Child,
                                                                Child_Field);
                                                         Held : constant
                                                           Ty.Scalar_Name :=
                                                             Shape.Element;
                                                         Signature : constant
                                                           IR.Signature_Id :=
                                                           (if
                                                              Shape.Signature
                                                                /= 0
                                                            then Signature_For
                                                              (Shape.Signature)
                                                            else
                                                              IR.No_Signature);
                                                         Part : constant
                                                           IR.Part_Position :=
                                                             IR.Part_Position
                                                               (if
                                                                  Source_Parent
                                                                    = 0
                                                                then
                                                                  Child_Field
                                                                else
                                                                  Source_Parent
                                                               );
                                                         Nested : constant
                                                           Natural :=
                                                             (if Source_Parent
                                                                   = 0
                                                              then 0
                                                              else
                                                                Child_Field);
                                                         Origin : constant
                                                           Landin.Provenance
                                                             .Origin :=
                                                               Site_Of
                                                                 (Of_Tree,
                                                                  Value);
                                                         Taken : IR.Value_Id;
                                                      begin
                                                         case Source.Kind is
                                                            when IR
                                                              .Module_Datum =>
                                                               Taken := IR
                                                             .Emit_Load_Field
                                                                   (Unit.all,
                                                                    Filling,
                                                                    Source
                                                                      .Datum,
                                                                    Part,
                                                                    Held,
                                                                    Origin,
                                                             Nested =>
                                                               Below (Nested),
                                                             Signature =>
                                                               Signature);
                                                            when IR
                                                              .Frame_Slot =>
                                                               Taken := IR
                                                        .Emit_Load_Slot_Field
                                                                   (Unit.all,
                                                                    Filling,
                                                                    Source
                                                                      .Slot,
                                                                    Part,
                                                                    Held,
                                                                    Origin,
                                                             Nested =>
                                                               Below (Nested),
                                                             Signature =>
                                                               Signature);
                                                            when
                                                              Runtime_Address
                                                            =>
                                                               Impossible;
                                                         end case;
                                                         IR
                                                       .Emit_Store_Slot_Field
                                                         (Unit.all, Filling,
                                                            Temporary,
                                                            IR.Part_Position
                                                              (Field),
                                                            Taken, Origin,
                                                            Nested =>
                                                              Below
                                                                (Child_Field));
                                                      end;
                                                   when Landin.Checking
                                                     .Fixed_Array_Field =>
                                                      declare
                                                         Part : constant
                                                           Natural :=
                                                             (if Source_Parent
                                                                   = 0
                                                              then Child_Field
                                                              else
                                                                Source_Parent);
                                                         Nested : constant
                                                           Natural :=
                                                             (if Source_Parent
                                                                   = 0
                                                              then 0
                                                              else
                                                                Child_Field);
                                                      begin
                                                         IR.Emit_Array_Copy
                                                           (Unit.all, Filling,
                                                            Source => Source,
                                                            Destination =>
                                                              Destination,
                                                            Site => Site_Of
                                                              (Of_Tree, Value),
                                                            Source_Field =>
                                                              Part,
                                                            Source_Nested =>
                                                              Below (Nested),
                                                            Destination_Field
                                                              => Field,
                                                       Destination_Nested =>
                                                         Below (Child_Field));
                                                      end;
                                                   when others =>
                                                      raise
                                                        Landin.Compiler_Defect;
                                                end case;
                                             end loop;
                                          end;
                                       end if;
                                    end;
                              end case;
                              exit when Current = IR.No_Block;
                           end;
                        end loop;

                        if Current /= IR.No_Block
                          and then Construction_Fill (Of_Tree, Argument)
                             /= Syn.No_Node
                        then
                           for Field in Seen'Range loop
                              if not Seen (Field) then
                                 case Landin.Checking.Field_Kind_Of
                                   (Types.all, Id, Field)
                                 is
                                    when Landin.Checking.Scalar_Field =>
                                       declare
                                          Held : constant Ty.Scalar_Name :=
                                            Landin.Checking.Field_Type
                                              (Types.all, Id, Field);
                                          Zero : IR.Value_Id;
                                       begin
                                          if Held = Ty.Bool then
                                             Zero := IR.Emit_Truth
                                               (Unit.all, Filling, False,
                                                Site_Of (Of_Tree, Argument));
                                          else
                                             Zero := IR.Emit_Number
                                               (Unit.all, Filling, Held, 0,
                                                False,
                                                Site_Of (Of_Tree, Argument));
                                          end if;
                                          IR.Emit_Store_Slot_Field
                                            (Unit.all, Filling, Temporary,
                                             IR.Part_Position (Field), Zero,
                                             Site_Of (Of_Tree, Argument));
                                       end;
                                    when Landin.Checking.Fixed_Array_Field =>
                                       IR.Emit_Array_Clear
                                         (Unit.all, Filling,
                                          (Kind => IR.Frame_Slot,
                                           Slot => Temporary),
                                          Site_Of (Of_Tree, Argument),
                                          Field => Field);
                                    when Landin.Checking.Variant_Field =>
                                       IR.Emit_Variant_Select
                                         (Unit.all, Filling,
                                          (Kind => IR.Frame_Slot,
                                           Slot => Temporary),
                                          Field, 1,
                                          Site_Of (Of_Tree, Argument));
                                    when Landin.Checking.Aggregate_Field =>
                                       IR.Emit_Array_Clear
                                         (Unit.all, Filling,
                                          (Kind => IR.Frame_Slot,
                                           Slot => Temporary),
                                          Site_Of (Of_Tree, Argument),
                                          Field => Field);
                                 end case;
                              end if;
                           end loop;
                        end if;

                        if Current /= IR.No_Block then
                           Given (Which) := IR.Emit_Storage_Address
                             (Unit.all, Filling,
                              (Kind => IR.Frame_Slot, Slot => Temporary),
                              Site_Of (Of_Tree, Argument));
                        end if;
                     end;
                  elsif Syn.Kind (Of_Tree, Argument)
                          in Syn.Array_Literal | Syn.Array_Repetition
                             | Syn.Mixed_Array_Repetition
                  then
                     declare
                        Parameter : constant
                          Landin.Checking.Signature_Part :=
                            Landin.Checking.Nth_Signature_Parameter
                              (Types.all, Source_Signature, Which);
                        Temporary : constant IR.Slot_Id :=
                          IR.Add_Array_Slot
                            (Unit.all, Filling,
                             Parameter.Element,
                             IR.Element_Total (Parameter.Length),
                             Res.No_Declaration,
                             Site_Of (Of_Tree, Argument));
                        Prefix : constant Natural :=
                          (if Syn.Kind (Of_Tree, Argument)
                                in Syn.Array_Literal
                                   | Syn.Mixed_Array_Repetition
                           then Syn.Element_Count (Of_Tree, Argument)
                           else 0);
                     begin
                        for Position in 1 .. Prefix loop
                           declare
                              Element : constant Syn.Node_Id :=
                                Syn.Nth_Element
                                  (Of_Tree, Argument, Position);
                              Value : constant IR.Value_Id :=
                                Lower_Expression (Of_Tree, Element, Scope);
                           begin
                              if Current = IR.No_Block then
                                 return IR.No_Value;
                              end if;
                              declare
                                 Index : constant IR.Value_Id :=
                                   IR.Emit_Number
                                     (Unit.all, Filling, Ty.Usize,
                                      Ty.Magnitude (Position - 1), False,
                                      Site_Of (Of_Tree, Element));
                              begin
                                 IR.Emit_Store_Slot_Element
                                   (Unit.all, Filling, Temporary, Index,
                                    Value, Site_Of (Of_Tree, Element));
                              end;
                           end;
                        end loop;

                        if Syn.Kind (Of_Tree, Argument)
                             in Syn.Array_Repetition
                                | Syn.Mixed_Array_Repetition
                        then
                           declare
                              Repeated : constant Syn.Node_Id :=
                                Syn.Repeated_Element (Of_Tree, Argument);
                              Value : constant IR.Value_Id :=
                                Lower_Expression
                                  (Of_Tree, Repeated, Scope);
                           begin
                              if Current = IR.No_Block then
                                 return IR.No_Value;
                              end if;
                              IR.Emit_Array_Fill
                                (Unit.all, Filling,
                                 (Kind => IR.Frame_Slot,
                                  Slot => Temporary),
                                 IR.Part_Position (Prefix + 1),
                                 Value,
                                 Site_Of (Of_Tree, Repeated));
                           end;
                        end if;

                        Given (Which) := IR.Emit_Storage_Address
                          (Unit.all, Filling,
                           (Kind => IR.Frame_Slot, Slot => Temporary),
                           Site_Of (Of_Tree, Argument));
                     end;
                  else
                     if Has_Computed_Index (Of_Tree, Argument) then
                        declare
                           Reached : constant Stored_Place :=
                             Lower_Stored_Place
                               (Of_Tree, Argument, Scope);
                        begin
                           if Current = IR.No_Block then
                              return IR.No_Value;
                           end if;
                           declare
                              Place : constant IR.Storage :=
                                Addressed_Storage
                                  (Reached,
                                   Neutral_Value_Shape (Of_Tree, Argument),
                                   Site_Of (Of_Tree, Argument));
                           begin
                              Given (Which) :=
                                IR.Emit_Storage_Address
                                  (Unit.all, Filling, Place,
                                   Site_Of (Of_Tree, Argument));
                           end;
                        end;
                     else
                        declare
                           Field : constant Natural :=
                             Rooted_Base (Of_Tree, Argument);
                           Child_Steps : constant IR.Path_Step_Array :=
                             Rooted_Steps (Of_Tree, Argument);
                        begin
                           Given (Which) :=
                             IR.Emit_Storage_Address
                               (Unit.all, Filling, Rooted_Storage
                                  (Of_Tree, Argument),
                                Site_Of (Of_Tree, Argument),
                                Field => Field, Nested => Child_Steps);
                        end;
                     end if;
                  end if;
               else
                  Given (Which) :=
                    Lower_Expression (Of_Tree, Argument, Scope);
               end if;

               if Current = IR.No_Block then
                  return IR.No_Value;
               end if;

               if Which < Count then
                  Saved (Which) :=
                    IR.Add_Slot
                      (Unit.all, Filling,
                       (if Type_At (Of_Tree, Argument)
                              in Ty.Aggregate | Ty.Fixed_Array
                        then Ty.Usize else Scalar_At (Of_Tree, Argument)),
                       Res.No_Declaration, Site_Of (Of_Tree, Argument),
                       Signature =>
                         (if Type_At (Of_Tree, Argument) = Ty.Function_Value
                          then Signature_For
                            (Landin.Checking.Signature_Of
                               (Types.all, Of_Tree, Argument))
                          else IR.No_Signature),
                       Atoms =>
                         (if Type_At (Of_Tree, Argument) = Ty.Atom_Value
                          then Atom_Set_For
                            (Landin.Checking.Atom_Set_Of
                               (Types.all, Of_Tree, Argument))
                          else IR.No_Atom_Set));
                  IR.Emit_Store
                    (Unit.all, Filling, Saved (Which), Given (Which),
                     Site_Of (Of_Tree, Argument));
               end if;
            end;
         end loop;

         --  Every argument must precede the call, because Add_Argument
         --  requires the call to remain the last instruction emitted.
         for Which in 1 .. Count loop
            if Which < Count then
               Given (Which) :=
                 IR.Emit_Load (Unit.all, Filling, Saved (Which), Site);
            end if;
         end loop;

         if Returns_Stored then
            pragma Assert (Destination /= IR.No_Slot);
            Hidden := IR.Emit_Storage_Address
              (Unit.all, Filling,
               (Kind => IR.Frame_Slot, Slot => Destination), Site,
               Field => Destination_Field,
               Nested => Destination_Steps);
         end if;

         if Indirect then
            Callee_Value :=
              IR.Emit_Load (Unit.all, Filling, Callee_Saved, Site);
         end if;

         Made :=
           (if Indirect
            then IR.Emit_Indirect_Call
              (Unit.all, Filling, Signature,
               (if Returns_Stored then Ty.No_Value
                elsif Type_At (Of_Tree, Node) = Ty.Function_Value
                then Ty.Usize
                elsif Type_At (Of_Tree, Node) = Ty.Atom_Value
                then Ty.U32 else Type_At (Of_Tree, Node)),
               Site, Failure => Failure_Slot)
            else IR.Emit_Call
              (Unit.all, Filling, Target,
               (if Returns_Stored then Ty.No_Value
                elsif Type_At (Of_Tree, Node) = Ty.Function_Value
                then Ty.Usize
                elsif Type_At (Of_Tree, Node) = Ty.Atom_Value
                then Ty.U32 else Type_At (Of_Tree, Node)),
               Site, Failure => Failure_Slot));

         if Indirect then
            IR.Add_Argument (Unit.all, Filling, Made, Callee_Value);
         end if;

         if Returns_Stored then
            IR.Add_Argument (Unit.all, Filling, Made, Hidden);
         end if;

         for Which in 1 .. Count loop
            IR.Add_Argument (Unit.all, Filling, Made, Given (Which));
         end loop;

         if Error_Set = IR.No_Atom_Set then
            return Made;
         end if;

         if Success_Slot /= IR.No_Slot then
            IR.Emit_Store
              (Unit.all, Filling, Success_Slot, Made, Site);
         end if;

         declare
            Error_Value : constant IR.Value_Id :=
              IR.Emit_Load (Unit.all, Filling, Failure_Slot, Site);
            Has_Error : constant IR.Value_Id :=
              IR.Emit_Failure_Test
                (Unit.all, Filling, Error_Value, Site);
            Failed_Block : constant IR.Block_Id :=
              Fresh (Of_Tree, Node, Scope);
            Success_Block : constant IR.Block_Id :=
              Fresh (Of_Tree, Node, Scope);
         begin
            IR.Emit_Branch
              (Unit.all, Filling, Has_Error,
               Failed_Block, Success_Block, Site);
            IR.Leave_Block (Unit.all, Filling);
            Current := IR.No_Block;

            if Propagate then
               Open (Failed_Block);
               declare
                  Error : constant IR.Value_Id :=
                    IR.Emit_Load
                      (Unit.all, Filling, Failure_Slot, Site);
               begin
                  Fail_Through_Cleanups (Of_Tree, Error, Site);
               end;

               Open (Success_Block);
               if Success_Slot /= IR.No_Slot then
                  return IR.Emit_Load
                    (Unit.all, Filling, Success_Slot, Site);
               end if;
               return Made;
            end if;

            if Syn.Recovery_Of (Of_Tree, Node) = Syn.No_Node then
               raise Landin.Compiler_Defect with
                 "a failing call reached lowering without try or else";
            end if;

            declare
               Recovery : constant Syn.Node_Id :=
                 Syn.Recovery_Of (Of_Tree, Node);
               Recovery_Body : constant Syn.Node_Id :=
                 Syn.Else_Body (Of_Tree, Recovery);
               Recovery_Scope : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Recovery);
               Join : constant IR.Block_Id :=
                 Fresh (Of_Tree, Recovery, Scope);
            begin
               Open (Failed_Block);
               if Syn.Name (Of_Tree, Recovery)
                    /= Landin.Source.Names.No_Name
               then
                  declare
                     Id : constant Res.Declaration_Id :=
                       Declaration_At
                         (Syn.Source_Of (Of_Tree), Recovery);
                     Error : constant IR.Value_Id :=
                       IR.Emit_Load
                         (Unit.all, Filling, Failure_Slot, Site);
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling,
                        Slot_For (Of_Tree, Recovery, Id), Error, Site);
                  end;
               end if;

               if Syn.Kind (Of_Tree, Recovery_Body) = Syn.Block then
                  Lower_Statements
                    (Of_Tree, Recovery_Body, Recovery_Scope,
                     Active_Result,
                     Destination =>
                       (if Returns_Stored then Destination
                        else Success_Slot),
                     Destination_Field =>
                       (if Returns_Stored then Destination_Field else 0),
                     Destination_Path =>
                       (if Returns_Stored
                        then Destination_Steps else IR.No_Path_Steps));
               elsif Returns_Stored then
                  Lower_Stored_Expression
                    (Of_Tree, Recovery_Body, Recovery_Scope, Destination,
                     Destination_Field, Destination_Steps);
               else
                  declare
                     Recovered : constant IR.Value_Id :=
                       Lower_Expression
                         (Of_Tree, Recovery_Body, Recovery_Scope);
                  begin
                     if Current /= IR.No_Block
                       and then Success_Slot /= IR.No_Slot
                     then
                        IR.Emit_Store
                          (Unit.all, Filling, Success_Slot, Recovered, Site);
                     end if;
                  end;
               end if;

               if Current /= IR.No_Block then
                  Close_With_Jump (Join, Site);
               end if;

               Open (Success_Block);
               Close_With_Jump (Join, Site);
               Open (Join);
               if Success_Slot /= IR.No_Slot then
                  return IR.Emit_Load
                    (Unit.all, Filling, Success_Slot, Site);
               end if;
               return Made;
            end;
         end;
      end Lower_Call;

      ------------------------------------------------------------
      --  Expressions [1820]
      ------------------------------------------------------------

      function Lower_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);

         --  [1880]: a unary minus over a literal is part of the value the
         --  literal check read, which is what makes `i8 = -128` the
         --  smallest i8 rather than 128 refused and then negated.  So it
         --  is one Number here, and not a Negation over one.
         function Magnitude_Of (Literal : Syn.Node_Id) return Ty.Magnitude;

         function Magnitude_Of (Literal : Syn.Node_Id) return Ty.Magnitude
         is
            Text : constant String :=
              Landin.Source.Slice
                (Landin.Stages.Source (Context, Syn.Source_Of (Of_Tree)),
                 Syn.Digit_Span (Of_Tree, Literal));
            Value      : Ty.Magnitude;
            Overflowed : Boolean;
         begin
            Ty.Evaluate
              (Text, Syn.Base (Of_Tree, Literal), Value, Overflowed);

            if Overflowed then
               raise Landin.Compiler_Defect with
                 "a literal the checker accepted does not fit Magnitude";
            end if;

            return Value;
         end Magnitude_Of;

      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block =>
               return Lower_Control_Expression (Of_Tree, Node, Scope);

            when Syn.Integer_Literal =>
               return IR.Emit_Number
                        (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                         Magnitude_Of (Node), False, Site);

            when Syn.True_Literal =>
               return IR.Emit_Truth (Unit.all, Filling, True, Site);

            when Syn.False_Literal =>
               return IR.Emit_Truth (Unit.all, Filling, False, Site);

            when Syn.Zeroed_Literal =>
               --  D40--D43: the checker admits this expression only where a
               --  scalar initializer or assignment destination supplies its
               --  type.  Reuse D10/D39's constants; the surrounding binding or
               --  assignment path emits its ordinary store.
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Node) = Ty.Bool
               then
                  return IR.Emit_Truth (Unit.all, Filling, False, Site);
               else
                  return IR.Emit_Number
                           (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                            0, False, Site);
               end if;

            --  [0370]: the type asked about is carried into the IR and the
            --  target-dependent answer is not.  D17 decomposes a fixed array
            --  into operations the IR already has; D44/D45 carry an ordinary
            --  struct as its declaration-order scalar or compact fixed-array
            --  field run; D74/D75 also carry shared variant case payload
            --  runs.  A nonempty array has its element's alignment;
            --  the internal empty shape has size zero and alignment one.
            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Asked);
                  Result : constant Ty.Scalar_Name :=
                    Scalar_At (Of_Tree, Node);
               begin
                  if Held = Ty.Aggregate then
                     declare
                        Declared : constant Landin.Checking.Nominal_Type_Id :=
                          Landin.Checking.Nominal_Of
                            (Types.all, Of_Tree, Asked);
                        function Total_Cases return Natural;
                        function Total_Payload_Fields return Natural;

                        function Total_Cases return Natural is
                           Total : Natural := 0;
                        begin
                           for Field in 1 .. Landin.Checking.Layout_Field_Count
                             (Types.all, Declared)
                           loop
                              if Landin.Checking.Field_Kind_Of
                                (Types.all, Declared, Field)
                                  = Landin.Checking.Variant_Field
                              then
                                 Total := Total
                                   + Landin.Checking.Field_Shape_Of
                                      (Types.all, Declared, Field).Cases;
                              end if;
                           end loop;
                           return Total;
                        end Total_Cases;

                        function Total_Payload_Fields return Natural is
                           Total : Natural := 0;
                        begin
                           for Field in 1 .. Landin.Checking.Layout_Field_Count
                             (Types.all, Declared)
                           loop
                              if Landin.Checking.Field_Kind_Of
                                (Types.all, Declared, Field)
                                  = Landin.Checking.Variant_Field
                              then
                                 for Which in 1 ..
                                   Landin.Checking.Field_Shape_Of
                                     (Types.all, Declared, Field).Cases
                                 loop
                                    Total := Total +
                                      Landin.Checking.Variant_Case_Field_Count
                                        (Types.all, Declared, Field, Which);
                                 end loop;
                              elsif Landin.Checking.Field_Kind_Of
                                (Types.all, Declared, Field)
                                  = Landin.Checking.Aggregate_Field
                              then
                                 Total := Total
                                   + Landin.Checking.Layout_Field_Count
                                       (Types.all,
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field)
                                            .Nominal);
                              end if;
                           end loop;
                           return Total;
                        end Total_Payload_Fields;

                        Fields : IR.Field_Shape_Array
                          (1 .. Landin.Checking.Layout_Field_Count
                                  (Types.all, Declared));
                        Cases : IR.Case_Run_Array (1 .. Total_Cases) :=
                          [others => (others => 0)];
                        Payloads : IR.Field_Shape_Array
                          (1 .. Total_Payload_Fields) :=
                            [others => (others => <>)];
                        Next_Case : Natural := 1;
                        Next_Payload : Natural := 1;
                     begin
                        for Field in Fields'Range loop
                           case Landin.Checking.Field_Kind_Of
                             (Types.all, Declared, Field)
                           is
                              when Landin.Checking.Scalar_Field =>
                                 declare
                                    Shape : constant
                                      Landin.Checking.Field_Shape :=
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field);
                                 begin
                                    Fields (Field) :=
                                      (Kind      => IR.Scalar_Field_Shape,
                                       Element   => Shape.Element,
                                       Length    => 1,
                                       Signature =>
                                         (if Shape.Signature /=
                                               Landin.Checking.No_Signature
                                          then Signature_For
                                            (Shape.Signature)
                                          else IR.No_Signature),
                                       others    => <>);
                                 end;

                              when Landin.Checking.Fixed_Array_Field =>
                                 Fields (Field) :=
                                   (Kind    => IR.Array_Field_Shape,
                                    Element =>
                                      Landin.Checking.Field_Array_Element
                                        (Types.all, Declared, Field),
                                    Length  => IR.Element_Total
                                      (Landin.Checking.Field_Array_Length
                                         (Types.all, Declared, Field)),
                                    others  => <>);

                              when Landin.Checking.Aggregate_Field =>
                                 declare
                                    Shape : constant
                                      Landin.Checking.Field_Shape :=
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field);
                                    Child : constant
                                      Landin.Checking.Nominal_Type_Id :=
                                      Shape.Nominal;
                                    Count : constant Natural :=
                                      Landin.Checking.Layout_Field_Count
                                        (Types.all, Child);
                                 begin
                                    Fields (Field) :=
                                      (Kind           =>
                                         IR.Aggregate_Field_Shape,
                                       Element        => Ty.Bool,
                                       Length         => 1,
                                       Cases          => Count,
                                       Payloads_First => Next_Payload,
                                       Nominal        => Nominal_For (Child),
                                       others         => <>);

                                    for Position in 1 .. Count loop
                                       declare
                                          Part : constant Landin.Checking
                                            .Field_Shape :=
                                              Landin.Checking.Field_Shape_Of
                                                (Types.all, Child, Position);
                                       begin
                                          Payloads (Next_Payload) :=
                                            (Kind =>
                                               (if Part.Kind =
                                                  Landin.Checking.Scalar_Field
                                                then IR.Scalar_Field_Shape
                                                else IR.Array_Field_Shape),
                                             Element => Part.Element,
                                             Length  => IR.Element_Total
                                               (Part.Length),
                                             others  => <>);
                                          Next_Payload := Next_Payload + 1;
                                       end;
                                    end loop;
                                 end;

                              when Landin.Checking.Variant_Field =>
                                 declare
                                    Shape : constant
                                      Landin.Checking.Field_Shape :=
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field);
                                 begin
                                    Fields (Field) :=
                                      (Kind           =>
                                         IR.Variant_Field_Shape,
                                       Element        => Shape.Element,
                                       Length         => 1,
                                       Cases          => Shape.Cases,
                                       Payloads_First => Next_Case,
                                       others         => <>);

                                    for Which in 1 .. Shape.Cases loop
                                       declare
                                          Count : constant Natural :=
                                            Landin.Checking
                                              .Variant_Case_Field_Count
                                                (Types.all, Declared,
                                                 Field, Which);
                                       begin
                                          Cases (Next_Case) :=
                                            (First =>
                                               (if Count = 0
                                                then 0 else Next_Payload),
                                             Count => Count);
                                          Next_Case := Next_Case + 1;

                                          for Position in 1 .. Count loop
                                             declare
                                                Part : constant Landin.Checking
                                                  .Field_Shape :=
                                                    Landin.Checking
                                                      .Nth_Variant_Case_Field
                                                        (Types.all, Declared,
                                                         Field, Which,
                                                         Position);
                                             begin
                                                Payloads (Next_Payload) :=
                                                  (Kind =>
                                                     (if Part.Kind =
                                                        Landin.Checking
                                                          .Scalar_Field
                                                      then IR
                                                        .Scalar_Field_Shape
                                                      else IR
                                                        .Array_Field_Shape),
                                                   Element => Part.Element,
                                                   Length  => IR.Element_Total
                                                     (Part.Length),
                                                   others  => <>);
                                                Next_Payload :=
                                                  Next_Payload + 1;
                                             end;
                                          end loop;
                                       end;
                                    end loop;
                                 end;
                           end case;
                        end loop;

                        return IR.Emit_Aggregate_Measurement
                          (Unit.all, Filling,
                           (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                            then IR.Measure_Size else IR.Measure_Align),
                           Fields, Result, Site,
                           Cases => Cases, Payloads => Payloads);
                     end;
                  elsif Held /= Ty.Fixed_Array then
                     return IR.Emit_Measurement
                              (Unit.all, Filling,
                               (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                                then IR.Measure_Size else IR.Measure_Align),
                               Ty.Scalar_Name (Held), Result, Site);
                  end if;

                  declare
                     Length : constant Landin.Checking.Element_Count :=
                       Landin.Checking.Array_Length
                         (Types.all, Of_Tree, Asked);
                     Element : constant Ty.Scalar_Name :=
                       Landin.Checking.Array_Element
                         (Types.all, Of_Tree, Asked);
                  begin
                     if Syn.Kind (Of_Tree, Node) = Syn.Align_Of then
                        if Length = 0 then
                           return IR.Emit_Number
                                    (Unit.all, Filling, Result,
                                     1, False, Site);
                        end if;

                        return IR.Emit_Measurement
                                 (Unit.all, Filling, IR.Measure_Align,
                                  Element, Result, Site);
                     end if;

                     declare
                        Element_Size : constant IR.Value_Id :=
                          IR.Emit_Measurement
                            (Unit.all, Filling, IR.Measure_Size,
                             Element, Result, Site);
                        Count : constant IR.Value_Id :=
                          IR.Emit_Number
                            (Unit.all, Filling, Result,
                             Ty.Magnitude (Length), False, Site);
                     begin
                        return IR.Emit_Binary
                                 (Unit.all, Filling, IR.Multiply,
                                  Count, Element_Size, Result, Site);
                     end;
                  end;
               end;

            --  [0370]: unlike byte measurements, an array's element count is
            --  target-neutral.  D14 takes it from a named array's type; D31
            --  takes it from a literal's source run without lowering an
            --  element.  Both use the existing usize Number.
            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
                  Length : constant Ty.Magnitude :=
                    (if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal
                     then Ty.Magnitude (Syn.Element_Count (Of_Tree, Asked))
                     else Ty.Magnitude
                            (Landin.Checking.Array_Length
                               (Types.all,
                                Res.Bound_To
                                  (Meanings.all, Of_Tree, Asked))));
               begin
                  return IR.Emit_Number
                           (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                            Length, False, Site);
               end;

            when Syn.Negation =>
               declare
                  Under : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Under) = Syn.Integer_Literal then
                     return IR.Emit_Number
                              (Unit.all, Filling,
                               Scalar_At (Of_Tree, Node),
                               Magnitude_Of (Under), True, Site);
                  end if;

                  declare
                     Value : constant IR.Value_Id :=
                       Lower_Expression (Of_Tree, Under, Scope);
                  begin
                     if Current = IR.No_Block then
                        return IR.No_Value;
                     end if;
                     return IR.Emit_Unary
                              (Unit.all, Filling, IR.Negation, Value,
                               Scalar_At (Of_Tree, Node), Site);
                  end;
               end;

            when Syn.Complement =>
               declare
                  Value : constant IR.Value_Id :=
                    Lower_Expression
                      (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope);
               begin
                  if Current = IR.No_Block then
                     return IR.No_Value;
                  end if;
                  return IR.Emit_Unary
                           (Unit.all, Filling, IR.Complement, Value,
                            Scalar_At (Of_Tree, Node), Site);
               end;

            when Syn.Logical_Not =>
               declare
                  Value : constant IR.Value_Id :=
                    Lower_Expression
                      (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope);
               begin
                  if Current = IR.No_Block then
                     return IR.No_Value;
                  end if;
                  return IR.Emit_Unary
                           (Unit.all, Filling, IR.Logical_Not, Value,
                            Scalar_At (Of_Tree, Node), Site);
               end;

            when Syn.Logical_And | Syn.Logical_Or =>
               return Lower_Short_Circuit (Of_Tree, Node, Scope);

            when Syn.Element_Index =>
               --  [0570]'s element of [1740]'s module array or [1810]'s
               --  local array.  A known position stays the compact static
               --  part operation; every other `usize` is an operand the
               --  backend checks before it forms an address [1950].  D22
               --  gives a local array the same computed-index path a
               --  module array has, reaching a frame slot rather than a
               --  datum symbol.
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Selected_Array : constant Boolean :=
                    Chain_Depth (Of_Tree, From) > 0;
                  Named : constant Syn.Node_Id :=
                    Chain_Root (Of_Tree, From);
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Named);
                  Field : constant Natural :=
                    Chain_Base (Of_Tree, From);
                  Child_Steps : constant IR.Path_Step_Array :=
                    Chain_Steps (Of_Tree, From);
               begin
                  if Aliases (Declared (Means)).Active then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                        Index : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
                     begin
                        if Current = IR.No_Block then
                           return IR.No_Value;
                        end if;
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive array match binding reached"
                             & " lowering";
                        end if;
                        case Alias.Source.Kind is
                           when IR.Module_Datum =>
                              return IR.Emit_Load_Element
                                (Unit.all, Filling, Alias.Source.Datum,
                                 Index, Scalar_At (Of_Tree, Node), Site,
                                 Field => Alias.Field,
                                 Nested => Alias_Steps (Of_Tree, Alias),
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Alias.Source.Slot,
                                 Index, Scalar_At (Of_Tree, Node), Site,
                                 Field => Alias.Field,
                                 Nested => Alias_Steps (Of_Tree, Alias),
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "an indexed runtime match alias reached"
                                & " scalar lowering";
                        end case;
                     end;
                  end if;

                  if Res.Sort_Of (Meanings.all, Means)
                     /= Res.Module_Binding
                  then
                     if Is_Constant_Index (Of_Tree, Node)
                       and then not Selected_Array
                     then
                        return IR.Emit_Load_Slot_Field
                                 (Unit.all, Filling,
                                  Slot_For (Of_Tree, Named, Means),
                                  Constant_Index (Of_Tree, Node),
                                  Scalar_At (Of_Tree, Node), Site);
                     end if;

                     declare
                        Index : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
                     begin
                        if Current = IR.No_Block then
                           return IR.No_Value;
                        end if;
                        return IR.Emit_Load_Slot_Element
                          (Unit.all, Filling,
                           Slot_For (Of_Tree, Named, Means), Index,
                           Scalar_At (Of_Tree, Node), Site,
                           Field => Field, Nested => Child_Steps);
                     end;
                  end if;

                  if Is_Constant_Index (Of_Tree, Node)
                    and then not Selected_Array
                  then
                     return IR.Emit_Load_Field
                              (Unit.all, Filling,
                               IR.Item_For (Unit.all, Means),
                               Constant_Index (Of_Tree, Node),
                               Scalar_At (Of_Tree, Node), Site);
                  end if;

                  declare
                     Index : constant IR.Value_Id :=
                       Lower_Expression
                         (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
                  begin
                     if Current = IR.No_Block then
                        return IR.No_Value;
                     end if;
                     return IR.Emit_Load_Element
                       (Unit.all, Filling, IR.Item_For (Unit.all, Means),
                        Index, Scalar_At (Of_Tree, Node), Site,
                        Field => Field, Nested => Child_Steps);
                  end;
               end;

            when Syn.Member_Selection =>
               --  [0750]'s field of a struct.  The checker settled which
               --  field the name selects, so this carries the answer
               --  rather than looking a name up a second time; what it
               --  is a field *of* decides whether the base is [1740]'s
               --  module state or a cell in this frame.
               declare
                  --  D121: the chain may pass through one index, and
                  --  then what it reaches is a leaf inside an element.
                  Indexed : constant Syn.Node_Id :=
                    Chain_Index (Of_Tree, Node);
                  Above : constant Syn.Node_Id :=
                    Chain_Above (Of_Tree, Node);
                  Place : constant IR.Storage :=
                    Rooted_Storage (Of_Tree, Above);
                  Base : constant Natural := Rooted_Base (Of_Tree, Above);
                  Child_Steps : constant IR.Path_Step_Array :=
                    Rooted_Steps (Of_Tree, Above);
                  Below : constant IR.Path_Step_Array :=
                    Chain_Below (Of_Tree, Node);
                  Value_Signature : constant IR.Signature_Id :=
                    (if Type_At (Of_Tree, Node) = Ty.Function_Value
                     then Signature_For
                       (Landin.Checking.Signature_Of
                          (Types.all, Of_Tree, Node))
                     else IR.No_Signature);
               begin
                  if Indexed /= Syn.No_Node then
                     declare
                        Index : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree, Syn.Index_Of (Of_Tree, Indexed),
                             Scope);
                     begin
                        case Place.Kind is
                           when IR.Module_Datum =>
                              return IR.Emit_Load_Element
                                (Unit.all, Filling, Place.Datum, Index,
                                 Scalar_At (Of_Tree, Node), Site,
                                 Field  => Base,
                                 Nested => Child_Steps,
                                 Below  => Below,
                                 Signature => Value_Signature);
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Place.Slot, Index,
                                 Scalar_At (Of_Tree, Node), Site,
                                 Field  => Base,
                                 Nested => Child_Steps,
                                 Below  => Below,
                                 Signature => Value_Signature);
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "a second computed index reached scalar"
                                & " lowering";
                        end case;
                     end;
                  end if;

                  case Place.Kind is
                     when IR.Module_Datum =>
                        return IR.Emit_Load_Field
                                 (Unit.all, Filling, Place.Datum,
                                  Leaf_Base (Base, Child_Steps),
                                  Scalar_At (Of_Tree, Node), Site,
                                  Nested => Leaf_Steps (Base, Child_Steps),
                                  Signature => Value_Signature);
                     when IR.Frame_Slot =>
                        return IR.Emit_Load_Slot_Field
                                 (Unit.all, Filling, Place.Slot,
                                  Leaf_Base (Base, Child_Steps),
                                  Scalar_At (Of_Tree, Node), Site,
                                  Nested => Leaf_Steps (Base, Child_Steps),
                                  Signature => Value_Signature);
                     when IR.Runtime_Address =>
                        raise Landin.Compiler_Defect with
                          "a runtime address reached scalar field lowering";
                  end case;
               end;

            when Syn.Anonymous_Function =>
               return IR.Emit_Function_Address
                 (Unit.all, Filling, Anonymous_Item (Of_Tree, Node), Site);

            when Syn.Name_Reference =>
               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Aliases (Declared (Means)).Active then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                        Held : constant Ty.Type_Kind :=
                          Landin.Checking.Type_Of (Types.all, Means);
                        Carrier : constant Ty.Scalar_Name :=
                          (if Held = Ty.Function_Value
                           then Ty.Usize else Ty.Scalar_Name (Held));
                        Signature : constant IR.Signature_Id :=
                          (if Held = Ty.Function_Value
                           then Signature_For
                             (Landin.Checking.Signature_Of
                                (Types.all, Means))
                           else IR.No_Signature);
                     begin
                        if Alias.Which /= 0 then
                           return IR.Emit_Variant_Field_Load
                             (Unit.all, Filling, Alias.Source,
                              Positive (Alias.Field), Positive (Alias.Which),
                              Positive (Alias.Payload_Field), Carrier, Site,
                              Nested => Alias_Steps (Of_Tree, Alias),
                              Signature => Signature);
                        end if;
                        case Alias.Source.Kind is
                           when IR.Module_Datum =>
                              return IR.Emit_Load_Field
                                (Unit.all, Filling, Alias.Source.Datum,
                                 IR.Part_Position (Alias.Field), Carrier,
                                 Site, Signature => Signature);
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Field
                                (Unit.all, Filling, Alias.Source.Slot,
                                 IR.Part_Position (Alias.Field), Carrier,
                                 Site, Signature => Signature);
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "a runtime aggregate alias reached direct"
                                & " scalar lowering";
                        end case;
                     end;
                  end if;

                  if Res.Sort_Of (Meanings.all, Means) = Res.Module_Atom then
                     return IR.Emit_Atom
                       (Unit.all, Filling, Means,
                        Atom_Set_For
                          (Landin.Checking.Atom_Set_Of (Types.all, Means)),
                        Site);
                  end if;

                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Module_Function
                  then
                     return IR.Emit_Function_Address
                       (Unit.all, Filling,
                        IR.Item_For (Unit.all, Means), Site);
                  end if;

                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Module_Binding
                  then
                     return IR.Emit_Load_Datum
                              (Unit.all, Filling,
                               IR.Item_For (Unit.all, Means), Site);
                  end if;

                  return IR.Emit_Load
                           (Unit.all, Filling,
                            Slot_For (Of_Tree, Node, Means), Site);
               end;

            when Syn.Try_Expression =>
               return Lower_Call
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope,
                  Propagate => True);

            when Syn.Call | Syn.Labeled_Application =>
               return Lower_Call (Of_Tree, Node, Scope);

            when others =>
               --  [0410] fixes the order: the left, then the right.  The
               --  right can change blocks, so the earlier value crosses
               --  through a slot and is loaded in the block where the
               --  operation is emitted.  This is the same block-local
               --  operand rule a call's earlier arguments follow.
               declare
                  Left_Node : constant Syn.Node_Id :=
                    Syn.Left_Of (Of_Tree, Node);
                  Right_Node : constant Syn.Node_Id :=
                    Syn.Right_Of (Of_Tree, Node);
                  Left : constant IR.Value_Id :=
                    Lower_Expression (Of_Tree, Left_Node, Scope);
               begin
                  if Current = IR.No_Block then
                     return IR.No_Value;
                  end if;

                  declare
                     Saved_Left : constant IR.Slot_Id :=
                       IR.Add_Slot
                         (Unit.all, Filling,
                          Scalar_At (Of_Tree, Left_Node),
                          Res.No_Declaration,
                          Site_Of (Of_Tree, Left_Node),
                          Atoms =>
                            (if Type_At (Of_Tree, Left_Node) = Ty.Atom_Value
                             then Atom_Set_For
                               (Landin.Checking.Atom_Set_Of
                                  (Types.all, Of_Tree, Left_Node))
                             else IR.No_Atom_Set));
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Saved_Left, Left,
                        Site_Of (Of_Tree, Left_Node));

                     declare
                        Right : constant IR.Value_Id :=
                          Lower_Expression (Of_Tree, Right_Node, Scope);
                     begin
                        if Current = IR.No_Block then
                           return IR.No_Value;
                        end if;
                        declare
                           Carried_Left : constant IR.Value_Id :=
                             IR.Emit_Load
                               (Unit.all, Filling, Saved_Left, Site);
                        begin
                           return IR.Emit_Binary
                                    (Unit.all, Filling,
                                     Opcode_For (Syn.Kind (Of_Tree, Node)),
                                     Carried_Left, Right,
                                     Scalar_At (Of_Tree, Node), Site);
                        end;
                     end;
                  end;
               end;
         end case;
      end Lower_Expression;

      ------------------------------------------------------------
      --  [1810]: a branch
      ------------------------------------------------------------

      procedure Lower_If
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Merge : IR.Block_Id := IR.No_Block;

         procedure Close_To_Merge;

         procedure Close_To_Merge is
         begin
            pragma Assert (Current /= IR.No_Block);
            if Merge = IR.No_Block then
               Merge := Fresh (Of_Tree, Node, Scope);
            end if;
            Close_With_Jump (Merge, Site);
         end Close_To_Merge;
      begin
         for Which in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
            declare
               This : constant Syn.Node_Id :=
                 Syn.Nth_Arm (Of_Tree, Node, Which);
               Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, This);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Test : constant IR.Value_Id :=
                 Lower_Expression
                   (Of_Tree, Syn.Condition_Of (Of_Tree, This), Scope);
            begin
               if Current = IR.No_Block then
                  return;
               end if;
               pragma Assert (Test /= IR.No_Value);

               declare
                  Taken : constant IR.Block_Id :=
                    Fresh (Of_Tree, Runs, Inside);
                  Next : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Scope);
               begin
                  IR.Emit_Branch
                    (Unit.all, Filling, Test, Taken, Next, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;

                  Open (Taken);
                  Lower_Statements
                    (Of_Tree, Runs, Inside, Result, Destination,
                     Destination_Field, Destination_Path);

                  if Current /= IR.No_Block then
                     Close_To_Merge;
                  end if;

                  --  The next arm's test, or the `else`, is written here.
                  Open (Next);
               end;
            end;
         end loop;

         if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
            declare
               Runs : constant Syn.Node_Id :=
                 Syn.Else_Body (Of_Tree, Node);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Otherwise : constant IR.Block_Id :=
                 Fresh (Of_Tree, Runs, Inside);
            begin
               --  A block of its own, because [1840] makes the `else` a
               --  scope of its own and a block carries one scope.
               Close_With_Jump (Otherwise, Site);
               Open (Otherwise);
               Lower_Statements
                 (Of_Tree, Runs, Inside, Result, Destination,
                  Destination_Field, Destination_Path);
            end;
         end if;

         if Current /= IR.No_Block then
            Close_To_Merge;
         end if;

         --  An expression whose every edge returned has no continuation.
         --  Allocate no orphan merge block for the verifier to reject.
         if Merge /= IR.No_Block then
            Open (Merge);
         end if;
      end Lower_If;

      ------------------------------------------------------------
      --  D77: an exhaustive unfolded-variant tag match
      ------------------------------------------------------------

      procedure Lower_Variant_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Subject : constant Syn.Node_Id :=
           Syn.Match_Subject (Of_Tree, Node);
         --  D126: the variant part may sit below the name.  Holder is the
         --  struct that declares it, Named is the name the chain started
         --  from, and Base/Steps is the run down to the part.
         Holder : constant Syn.Node_Id :=
           Syn.Target_Of (Of_Tree, Subject);
         Wrote : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Of_Tree, Holder);
         Field : constant Positive := Positive
           (Landin.Checking.Field_Index (Types.all, Of_Tree, Subject));
         Computed : constant Boolean :=
           Has_Computed_Index (Of_Tree, Holder);
         Location : Stored_Place;
         Alias_Subject : Syn.Node_Id := Subject;
         Shape : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Field_Shape_Of (Types.all, Wrote, Field);
         Tag_Type : constant Ty.Integer_Name :=
           Ty.Integer_Name (Shape.Element);
         Saved_Tag : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Shape.Element, Res.No_Declaration,
              Site_Of (Of_Tree, Subject));
         Merge : IR.Block_Id := IR.No_Block;

         procedure Bind (Arm : Syn.Node_Id);
         procedure Close_To_Merge;

         procedure Bind (Arm : Syn.Node_Id) is
            Which : constant Positive := Positive
              (Landin.Checking.Field_Index
                 (Types.all, Of_Tree, Syn.Match_Pattern (Of_Tree, Arm)));
         begin
            for Payload in 1 .. Syn.Match_Binding_Count (Of_Tree, Arm)
            loop
               declare
                  Binding : constant Syn.Node_Id :=
                    Syn.Nth_Match_Binding (Of_Tree, Arm, Payload);
                  Id : constant Res.Declaration_Id :=
                    Declaration_At (Syn.Source_Of (Of_Tree), Binding);
               begin
                  Aliases (Declared (Id)) :=
                    (Active        => True,
                     Source        => Location.Place,
                     Field         => Location.Base,
                     Subject       => Alias_Subject,
                     Which         => Which,
                     Payload_Field => Payload);
               end;
            end loop;
         end Bind;

         procedure Close_To_Merge is
         begin
            pragma Assert (Current /= IR.No_Block);
            if Merge = IR.No_Block then
               Merge := Fresh (Of_Tree, Node, Scope);
            end if;
            Close_With_Jump (Merge, Site);
         end Close_To_Merge;
      begin
         pragma Assert (Shape.Kind = Landin.Checking.Variant_Field);

         if Computed then
            Location := Lower_Stored_Place (Of_Tree, Holder, Scope);
            if Current = IR.No_Block then
               return;
            end if;
            declare
               Holder_Shape : constant IR.Field_Shape :=
                 Neutral_Body (Wrote);
               From : constant IR.Storage :=
                 Addressed_Storage (Location, Holder_Shape, Site);
               Temporary : constant IR.Slot_Id :=
                 IR.Add_Aggregate_Slot
                   (Unit.all, Filling, Res.No_Declaration, Site,
                    Nominal_For (Wrote));
               Temp_Storage : constant IR.Storage :=
                 (Kind => IR.Frame_Slot, Slot => Temporary);
            begin
               for Part in
                 1 .. Landin.Checking.Layout_Field_Count (Types.all, Wrote)
               loop
                  Add_Stored_Field (Wrote, Part, Slot => Temporary);
               end loop;
               declare
                  Temp : constant Stored_Place :=
                    (Place => Temp_Storage, Base => 0,
                     Steps => Stored_Path_Vectors.Empty_Vector);
                  Into : constant IR.Storage :=
                    Addressed_Storage (Temp, Holder_Shape, Site);
               begin
                  IR.Emit_Array_Copy
                    (Unit.all, Filling, From, Into, Site);
               end;
               Location.Place := Temp_Storage;
               Location.Base := Field;
               Location.Steps.Clear;
               Alias_Subject := Syn.No_Node;
            end;
         else
            declare
               Reached : constant Natural :=
                 Rooted_Base (Of_Tree, Subject);
               Walked : constant IR.Path_Step_Array :=
                 Rooted_Steps (Of_Tree, Subject);
            begin
               Location.Place := Rooted_Storage (Of_Tree, Subject);
               Location.Base := Natural (Leaf_Base (Reached, Walked));
               for Step of Leaf_Steps (Reached, Walked) loop
                  Location.Steps.Append (Step);
               end loop;
            end;
         end if;

         --  The selected storage is read exactly once.  A scalar slot is
         --  the IR's block-crossing carrier for the cascade of comparisons.
         declare
            Loaded : constant IR.Value_Id :=
              IR.Emit_Variant_Tag_Load
                (Unit.all, Filling, Location.Place,
                 Positive (Location.Base), Shape.Element, Site,
                 Nested => Stored_Steps (Location));

         begin
            IR.Emit_Store
              (Unit.all, Filling, Saved_Tag, Loaded, Site);
         end;

         for Position in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
            declare
               Arm : constant Syn.Node_Id :=
                 Syn.Nth_Match_Arm (Of_Tree, Node, Position);
               Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Arm);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Taken : constant IR.Block_Id :=
                 Fresh (Of_Tree, Runs, Inside);
            begin
               if Position < Syn.Match_Arm_Count (Of_Tree, Node) then
                  declare
                     Next : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Tag : constant IR.Value_Id :=
                       IR.Emit_Load
                         (Unit.all, Filling, Saved_Tag, Site);
                     Wanted : constant IR.Value_Id :=
                       IR.Emit_Number
                         (Unit.all, Filling, Tag_Type,
                          Ty.Magnitude
                            (Landin.Checking.Field_Index
                               (Types.all, Of_Tree,
                                Syn.Match_Pattern (Of_Tree, Arm)) - 1),
                          Negated => False,
                          Site    => Site);
                     Test : constant IR.Value_Id :=
                       IR.Emit_Binary
                         (Unit.all, Filling, IR.Equal_To,
                          Tag, Wanted, Ty.Bool, Site);
                  begin
                     IR.Emit_Branch
                       (Unit.all, Filling, Test, Taken, Next, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Taken);
                     Bind (Arm);
                     Lower_Statements
                       (Of_Tree, Runs, Inside, Result, Destination,
                        Destination_Field, Destination_Path);
                     if Current /= IR.No_Block then
                        Close_To_Merge;
                     end if;

                     Open (Next);
                  end;
               else
                  --  Exhaustiveness makes the final arm the only remaining
                  --  tag; it still gets its own lexical block.
                  Close_With_Jump (Taken, Site);
                  Open (Taken);
                  Bind (Arm);
                  Lower_Statements
                    (Of_Tree, Runs, Inside, Result, Destination,
                     Destination_Field, Destination_Path);
                  if Current /= IR.No_Block then
                     Close_To_Merge;
                  end if;
               end if;
            end;
         end loop;

         if Merge /= IR.No_Block then
            Open (Merge);
         end if;
      end Lower_Variant_Match;

      procedure Lower_Atom_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Subject : constant Syn.Node_Id :=
           Syn.Match_Subject (Of_Tree, Node);
         Set_Id : constant IR.Atom_Set_Id :=
           Atom_Set_For
             (Landin.Checking.Atom_Set_Of
                (Types.all, Of_Tree, Subject));
         Saved : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site,
              Atoms => Set_Id);
         Merge : IR.Block_Id := IR.No_Block;

         procedure Close_To_Merge;

         procedure Close_To_Merge is
         begin
            if Merge = IR.No_Block then
               Merge := Fresh (Of_Tree, Node, Scope);
            end if;
            Close_With_Jump (Merge, Site);
         end Close_To_Merge;
      begin
         declare
            Value : constant IR.Value_Id :=
              Lower_Expression (Of_Tree, Subject, Scope);
         begin
            if Current = IR.No_Block then
               return;
            end if;
            IR.Emit_Store (Unit.all, Filling, Saved, Value, Site);
         end;

         for Position in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
            declare
               Arm : constant Syn.Node_Id :=
                 Syn.Nth_Match_Arm (Of_Tree, Node, Position);
               Pattern : constant Syn.Node_Id :=
                 Syn.Match_Pattern (Of_Tree, Arm);
               Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Arm);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Taken : constant IR.Block_Id :=
                 Fresh (Of_Tree, Runs, Inside);
               Wildcard : constant Boolean :=
                 Syn.Name (Of_Tree, Pattern)
                   = Landin.Source.Names.No_Name;
               Last : constant Boolean :=
                 Position = Syn.Match_Arm_Count (Of_Tree, Node);
            begin
               if Wildcard or else Last then
                  Close_With_Jump (Taken, Site);
                  Open (Taken);
                  Lower_Statements
                    (Of_Tree, Runs, Inside, Result, Destination,
                     Destination_Field, Destination_Path);
                  if Current /= IR.No_Block then
                     Close_To_Merge;
                  end if;
                  exit when Wildcard;
               else
                  declare
                     Next : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Means : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, Pattern);
                     Got : constant IR.Value_Id :=
                       IR.Emit_Load (Unit.all, Filling, Saved, Site);
                     Wanted : constant IR.Value_Id :=
                       IR.Emit_Atom
                         (Unit.all, Filling, Means,
                          Atom_Set_For
                            (Landin.Checking.Atom_Set_Of
                               (Types.all, Means)), Site);
                     Test : constant IR.Value_Id :=
                       IR.Emit_Binary
                         (Unit.all, Filling, IR.Equal_To,
                          Got, Wanted, Ty.Bool, Site);
                  begin
                     IR.Emit_Branch
                       (Unit.all, Filling, Test, Taken, Next, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Taken);
                     Lower_Statements
                       (Of_Tree, Runs, Inside, Result, Destination,
                        Destination_Field, Destination_Path);
                     if Current /= IR.No_Block then
                        Close_To_Merge;
                     end if;

                     Open (Next);
                  end;
               end if;
            end;
         end loop;

         if Merge /= IR.No_Block then
            Open (Merge);
         end if;
      end Lower_Atom_Match;

      procedure Lower_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps) is
      begin
         if Type_At (Of_Tree, Syn.Match_Subject (Of_Tree, Node))
              = Ty.Atom_Value
         then
            Lower_Atom_Match
              (Of_Tree, Node, Scope, Result, Destination,
               Destination_Field, Destination_Path);
         else
            Lower_Variant_Match
              (Of_Tree, Node, Scope, Result, Destination,
               Destination_Field, Destination_Path);
         end if;
      end Lower_Match;

      procedure Lower_Bare_Block
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Node);
         Inside : constant Res.Scope_Id :=
           Res.Scope_At (Meanings.all, Of_Tree, Runs);
         Start : constant IR.Block_Id := Fresh (Of_Tree, Runs, Inside);
      begin
         Close_With_Jump (Start, Site);
         Open (Start);
         Lower_Statements
           (Of_Tree, Runs, Inside, Result, Destination,
            Destination_Field, Destination_Path);
         if Current /= IR.No_Block then
            declare
               Merge : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
            begin
               Close_With_Jump (Merge, Site);
               Open (Merge);
            end;
         end if;
      end Lower_Bare_Block;

      ------------------------------------------------------------
      --  [1810]: statements
      ------------------------------------------------------------

      procedure Lower_Statements
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Last_Statement : constant Natural :=
           Syn.Statement_Count (Of_Tree, Block);
         Has_Value : constant Boolean :=
           Syn.Block_Value (Of_Tree, Block) /= Syn.No_Node;
         Cleanup_Base : constant Natural := Natural (Cleanup_Stack.Length);
      begin
         for Which in
           1 .. Last_Statement + (if Has_Value then 1 else 0)
         loop
            exit when Current = IR.No_Block;

            declare
               Final_Value : constant Boolean := Which > Last_Statement;
               Stmt : constant Syn.Node_Id :=
                 (if Final_Value
                  then Syn.Block_Value (Of_Tree, Block)
                  else Syn.Nth_Statement (Of_Tree, Block, Which));
               Site : constant Landin.Provenance.Origin :=
                 Site_Of (Of_Tree, Stmt);

               --  [0410] evaluates a destination place before its value.
               --  A computed index is the enabled place operation that can
               --  do work, so lower it once and carry that same IR value
               --  through a read-modify-write.
               function Index_For (Place : Syn.Node_Id) return IR.Value_Id;

               function Read_Place
                 (Place : Syn.Node_Id; Index : IR.Value_Id)
                  return IR.Value_Id;

               --  [1900]: a place is a name, and which of the two kinds
               --  it is decides whether a Store or a Store_Datum says it.
               procedure Write
                 (Place : Syn.Node_Id;
                  Value : IR.Value_Id;
                  Index : IR.Value_Id := IR.No_Value);

               --  One field of [0710]'s copy, read from storage on the right
               --  and written to storage on the left.  D55 also supplies a
               --  fresh destination slot that has no source-level place.
               --  D119: one field copied between two places, each a
               --  base field and D118's run below it.  An ordinary child
               --  recurses, so the depth of the copy is the depth of the
               --  type and not of this procedure.
               procedure Copy_Field
                 (Wrote       : Landin.Checking.Nominal_Type_Id;
                  Source      : IR.Storage;
                  Destination : IR.Storage;
                  Field       : Positive;
                  Source_Base : Natural := 0;
                  Source_Steps : IR.Path_Step_Array := IR.No_Path_Steps;
                  Destination_Base : Natural := 0;
                  Destination_Steps : IR.Path_Step_Array :=
                    IR.No_Path_Steps);

               procedure Copy_Aggregate_Value
                 (Wrote       : Landin.Checking.Nominal_Type_Id;
                  Source_Node : Syn.Node_Id;
                  Destination : IR.Storage;
                  Destination_Base : Natural := 0;
                  Destination_Steps : IR.Path_Step_Array :=
                    IR.No_Path_Steps);

               procedure Copy_Result_Field
                 (Signature   : Landin.Checking.Signature_Id;
                  Source      : IR.Storage;
                  Destination : IR.Storage;
                  Field       : Positive);

               procedure Write_Array_Value
                 (Value       : Syn.Node_Id;
                  Destination : IR.Storage;
                  Field       : Natural;
                  Path : IR.Path_Step_Array := IR.No_Path_Steps;
                  Variant_Case : Natural := 0;
                  Variant_Payload_Field : Natural := 0);

               --  D126: the variant part may sit below the base field,
               --  so the place is a base and D118's run down to it.  Wrote
               --  and Field stay the checker's identity for the part, which
               --  is what the case and payload shapes are looked up by.
               procedure Write_Variant_Value
                 (Value       : Syn.Node_Id;
                  Wrote       : Landin.Checking.Nominal_Type_Id;
                  Field       : Positive;
                  Destination : IR.Storage;
                  Base        : Positive;
                  Steps       : IR.Path_Step_Array := IR.No_Path_Steps);

               --  D119: the literal fills a place, which is a base field
               --  and D118's run below it.  A labelled child is the same
               --  procedure one place deeper, so a literal nests as far as
               --  the type does.
               procedure Write_Struct_Literal
                 (Literal     : Syn.Node_Id;
                  Wrote       : Landin.Checking.Nominal_Type_Id;
                  Destination : IR.Storage;
                  Base        : Natural := 0;
                  Steps       : IR.Path_Step_Array := IR.No_Path_Steps);

               procedure Copy_Field
                 (Wrote       : Landin.Checking.Nominal_Type_Id;
                  Source      : IR.Storage;
                  Destination : IR.Storage;
                  Field       : Positive;
                  Source_Base : Natural := 0;
                  Source_Steps : IR.Path_Step_Array := IR.No_Path_Steps;
                  Destination_Base : Natural := 0;
                  Destination_Steps : IR.Path_Step_Array :=
                    IR.No_Path_Steps)
               is
                  From_Field : constant Natural :=
                    Descended_Base (Source_Base, Source_Steps, Field);
                  From_Steps : constant IR.Path_Step_Array :=
                    Descended_Steps (Source_Base, Source_Steps, Field);
                  Into_Field : constant Natural :=
                    Descended_Base
                      (Destination_Base, Destination_Steps, Field);
                  Into_Steps : constant IR.Path_Step_Array :=
                    Descended_Steps
                      (Destination_Base, Destination_Steps, Field);
               begin
                  case Landin.Checking.Field_Kind_Of
                    (Types.all, Wrote, Field)
                  is
                     when Landin.Checking.Scalar_Field =>
                        declare
                           Shape : constant Landin.Checking.Field_Shape :=
                             Landin.Checking.Field_Shape_Of
                               (Types.all, Wrote, Field);
                           Held : constant Ty.Scalar_Name := Shape.Element;
                           Signature : constant IR.Signature_Id :=
                             (if Shape.Signature /=
                                   Landin.Checking.No_Signature
                              then Signature_For (Shape.Signature)
                              else IR.No_Signature);
                           Taken : IR.Value_Id;
                        begin
                           --  D127: a field operation names one part and
                           --  a run below it, so a run that starts at
                           --  whole array storage gives its first step to
                           --  the part it names.
                           case Source.Kind is
                              when IR.Module_Datum =>
                                 Taken :=
                                   IR.Emit_Load_Field
                                     (Unit.all, Filling, Source.Datum,
                                      Leaf_Base (From_Field, From_Steps),
                                      Held, Site,
                                      Nested =>
                                        Leaf_Steps
                                          (From_Field, From_Steps),
                                      Signature => Signature);
                              when IR.Frame_Slot =>
                                 Taken :=
                                   IR.Emit_Load_Slot_Field
                                     (Unit.all, Filling, Source.Slot,
                                      Leaf_Base (From_Field, From_Steps),
                                      Held, Site,
                                      Nested =>
                                        Leaf_Steps
                                          (From_Field, From_Steps),
                                      Signature => Signature);
                              when IR.Runtime_Address =>
                                 raise Landin.Compiler_Defect with
                                   "a runtime address bypassed whole-copy"
                                   & " lowering";
                           end case;

                           case Destination.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Field
                                   (Unit.all, Filling, Destination.Datum,
                                    Leaf_Base (Into_Field, Into_Steps),
                                    Taken, Site,
                                    Nested =>
                                      Leaf_Steps (Into_Field, Into_Steps));
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Field
                                   (Unit.all, Filling, Destination.Slot,
                                    Leaf_Base (Into_Field, Into_Steps),
                                    Taken, Site,
                                    Nested =>
                                      Leaf_Steps (Into_Field, Into_Steps));
                              when IR.Runtime_Address =>
                                 raise Landin.Compiler_Defect with
                                   "a runtime address bypassed whole-copy"
                                   & " lowering";
                           end case;
                        end;

                     when Landin.Checking.Fixed_Array_Field =>
                        IR.Emit_Array_Copy
                          (Unit.all, Filling,
                           Source            => Source,
                           Destination       => Destination,
                           Site              => Site,
                           Source_Field      => From_Field,
                           Source_Nested     => From_Steps,
                           Destination_Field => Into_Field,
                           Destination_Nested => Into_Steps);

                     when Landin.Checking.Aggregate_Field =>
                        --  D119: a child is copied by copying its own
                        --  fields, one place deeper on both sides.
                        declare
                           Child : constant Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Field_Shape_Of
                               (Types.all, Wrote, Field).Nominal;
                        begin
                           for Part in
                             1 .. Landin.Checking.Layout_Field_Count
                                    (Types.all, Child)
                           loop
                              Copy_Field
                                (Child, Source, Destination, Part,
                                 Source_Base => From_Field,
                                 Source_Steps => From_Steps,
                                 Destination_Base => Into_Field,
                                 Destination_Steps => Into_Steps);
                           end loop;
                        end;

                     when Landin.Checking.Variant_Field =>
                        --  D126: a variant part inside a child is copied
                        --  by the same one operation, one place deeper on
                        --  each side.  The two places have one shape and
                        --  need not sit in the same place.
                        IR.Emit_Variant_Copy
                          (Unit.all, Filling,
                           Source        => Source,
                           Destination   => Destination,
                           Field         =>
                             Positive (Leaf_Base (From_Field, From_Steps)),
                           Site          => Site,
                           Source_Nested =>
                             Leaf_Steps (From_Field, From_Steps),
                           Destination_Field  =>
                             Positive (Leaf_Base (Into_Field, Into_Steps)),
                           Destination_Nested =>
                             Leaf_Steps (Into_Field, Into_Steps));
                  end case;
               end Copy_Field;

               procedure Copy_Aggregate_Value
                 (Wrote       : Landin.Checking.Nominal_Type_Id;
                  Source_Node : Syn.Node_Id;
                  Destination : IR.Storage;
                  Destination_Base : Natural := 0;
                  Destination_Steps : IR.Path_Step_Array :=
                    IR.No_Path_Steps)
               is
                  Source : Stored_Place;
                  Target : Stored_Place :=
                    (Place => Destination, Base => Destination_Base,
                     Steps => Stored_Path_Vectors.Empty_Vector);
               begin
                  for Step of Destination_Steps loop
                     Target.Steps.Append (Step);
                  end loop;

                  if Has_Computed_Index (Of_Tree, Source_Node)
                    or else Destination.Kind = IR.Runtime_Address
                  then
                     Source := Lower_Stored_Place
                       (Of_Tree, Source_Node, Scope);
                     if Current = IR.No_Block then
                        return;
                     end if;
                     declare
                        Shape : constant IR.Field_Shape :=
                          Neutral_Body (Wrote);
                        From : constant IR.Storage :=
                          Addressed_Storage
                            (Source, Shape,
                             Site_Of (Of_Tree, Source_Node));
                        Into : constant IR.Storage :=
                          Addressed_Storage (Target, Shape, Site);
                     begin
                        IR.Emit_Array_Copy
                          (Unit.all, Filling, From, Into, Site);
                     end;
                     return;
                  end if;

                  declare
                     Source_Base : constant Natural :=
                       Rooted_Base (Of_Tree, Source_Node);
                     Source_Steps : constant IR.Path_Step_Array :=
                       Rooted_Steps (Of_Tree, Source_Node);
                     Source_Storage : constant IR.Storage :=
                       Rooted_Storage (Of_Tree, Source_Node);
                  begin
                     for Field in
                       1 .. Landin.Checking.Layout_Field_Count
                              (Types.all, Wrote)
                     loop
                        Copy_Field
                          (Wrote, Source_Storage, Destination, Field,
                           Source_Base => Source_Base,
                           Source_Steps => Source_Steps,
                           Destination_Base => Destination_Base,
                           Destination_Steps => Destination_Steps);
                     end loop;
                  end;
               end Copy_Aggregate_Value;

               procedure Copy_Result_Field
                 (Signature   : Landin.Checking.Signature_Id;
                  Source      : IR.Storage;
                  Destination : IR.Storage;
                  Field       : Positive)
               is
                  Part : constant Landin.Checking.Signature_Part :=
                    Landin.Checking.Nth_Signature_Result
                      (Types.all, Signature, Field);
               begin
                  case Part.Kind is
                     when Ty.Scalar_Name | Ty.Function_Value =>
                        declare
                           Held : constant Ty.Scalar_Name :=
                             (if Part.Kind = Ty.Function_Value
                              then Ty.Usize else Ty.Scalar_Name (Part.Kind));
                           Function_Signature : constant IR.Signature_Id :=
                             (if Part.Kind = Ty.Function_Value
                              then Signature_For (Part.Signature)
                              else IR.No_Signature);
                           Value : IR.Value_Id;
                        begin
                           case Source.Kind is
                              when IR.Module_Datum =>
                                 Value := IR.Emit_Load_Field
                                   (Unit.all, Filling, Source.Datum,
                                    IR.Part_Position (Field), Held, Site,
                                    Signature => Function_Signature);
                              when IR.Frame_Slot =>
                                 Value := IR.Emit_Load_Slot_Field
                                   (Unit.all, Filling, Source.Slot,
                                    IR.Part_Position (Field), Held, Site,
                                    Signature => Function_Signature);
                              when IR.Runtime_Address =>
                                 raise Landin.Compiler_Defect with
                                   "an anonymous result used runtime"
                                   & " storage";
                           end case;
                           case Destination.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Field
                                   (Unit.all, Filling, Destination.Datum,
                                    IR.Part_Position (Field), Value, Site);
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Field
                                   (Unit.all, Filling, Destination.Slot,
                                    IR.Part_Position (Field), Value, Site);
                              when IR.Runtime_Address =>
                                 raise Landin.Compiler_Defect with
                                   "an anonymous result used runtime"
                                   & " storage";
                           end case;
                        end;

                     when Ty.Fixed_Array =>
                        IR.Emit_Array_Copy
                          (Unit.all, Filling, Source, Destination, Site,
                           Source_Field => Field,
                           Destination_Field => Field);

                     when Ty.Aggregate =>
                        --  Copy_Array is the compact shape-copy operation;
                        --  D128 also admits an aggregate-shaped reached field
                        --  with identity length one.
                        IR.Emit_Array_Copy
                          (Unit.all, Filling, Source, Destination, Site,
                           Source_Field => Field,
                           Destination_Field => Field);

                     when others =>
                        raise Landin.Compiler_Defect with
                          "a non-value result field reached copying";
                  end case;
               end Copy_Result_Field;

               procedure Write_Array_Value
                 (Value       : Syn.Node_Id;
                  Destination : IR.Storage;
                  Field       : Natural;
                  Path : IR.Path_Step_Array := IR.No_Path_Steps;
                  Variant_Case : Natural := 0;
                  Variant_Payload_Field : Natural := 0)
               is
                  procedure Store_Element
                    (Position : Positive; Element : IR.Value_Id);

                  procedure Store_Element
                    (Position : Positive; Element : IR.Value_Id)
                  is
                     Part : constant IR.Part_Position :=
                       IR.Part_Position (Position);
                  begin
                     if Field = 0 then
                        case Destination.Kind is
                           when IR.Module_Datum =>
                              IR.Emit_Store_Field
                                (Unit.all, Filling, Destination.Datum, Part,
                                 Element, Site);
                           when IR.Frame_Slot =>
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling, Destination.Slot, Part,
                                 Element, Site);
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "an array element write needs a containing"
                                & " field";
                        end case;
                     else
                        declare
                           Index : constant IR.Value_Id :=
                             IR.Emit_Number
                               (Unit.all, Filling, Ty.Usize,
                                Ty.Magnitude (Position - 1), False, Site);
                        begin
                           case Destination.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Element
                                   (Unit.all, Filling, Destination.Datum,
                                    Index, Element, Site, Field => Field,
                                    Nested => Path,
                                    Variant_Case => Variant_Case,
                                    Variant_Payload_Field =>
                                      Variant_Payload_Field);
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Element
                                   (Unit.all, Filling, Destination.Slot,
                                    Index, Element, Site, Field => Field,
                                    Nested => Path,
                                    Variant_Case => Variant_Case,
                                    Variant_Payload_Field =>
                                      Variant_Payload_Field);
                              when IR.Runtime_Address =>
                                 raise Landin.Compiler_Defect with
                                   "a runtime array field reached scalar"
                                   & " element lowering";
                           end case;
                        end;
                     end if;
                  end Store_Element;
               begin
                  --  D49--D53/D65: every contextual fixed-array destination
                  --  uses the same field-qualified operation family.  Field
                  --  zero is complete array storage; a positive field is the
                  --  array member of an aggregate datum or slot.
                  pragma Assert
                    ((Variant_Case = 0
                      and then Variant_Payload_Field = 0)
                     or else
                       (Field > 0
                        and then Variant_Case > 0
                        and then Variant_Payload_Field > 0));
                  pragma Assert
                    (Field = 0
                     or else Syn.Kind (Of_Tree, Value)
                               in Syn.Array_Literal
                                  | Syn.Array_Repetition
                                  | Syn.Mixed_Array_Repetition
                                  | Syn.Zeroed_Literal
                                  | Syn.Name_Reference
                                  | Syn.Member_Selection);

                  if Syn.Kind (Of_Tree, Value) = Syn.Array_Literal then
                     --  D29/D52 forms each contextual element directly in
                     --  destination storage in source order.
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        declare
                           Held : constant IR.Value_Id :=
                             Lower_Expression
                               (Of_Tree,
                                Syn.Nth_Element
                                  (Of_Tree, Value, Position), Scope);
                        begin
                           if Current = IR.No_Block then
                              return;
                           end if;
                           Store_Element (Position, Held);
                        end;
                     end loop;
                  elsif Syn.Kind (Of_Tree, Value)
                          = Syn.Mixed_Array_Repetition
                  then
                     --  D37/D53 writes each prefix position, then evaluates
                     --  one suffix value for the compact fill.
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        declare
                           Held : constant IR.Value_Id :=
                             Lower_Expression
                               (Of_Tree,
                                Syn.Nth_Element
                                  (Of_Tree, Value, Position), Scope);
                        begin
                           if Current = IR.No_Block then
                              return;
                           end if;
                           Store_Element (Position, Held);
                        end;
                     end loop;

                     declare
                        Held : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree,
                             Syn.Repeated_Element (Of_Tree, Value), Scope);
                     begin
                        if Current = IR.No_Block then
                           return;
                        end if;
                        IR.Emit_Array_Fill
                          (Unit.all, Filling, Destination,
                           IR.Part_Position
                             (Syn.Element_Count (Of_Tree, Value) + 1),
                           Held, Site, Field => Field,
                           Nested => Path,
                           Variant_Case => Variant_Case,
                           Variant_Payload_Field => Variant_Payload_Field);
                     end;
                  elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Repetition
                  then
                     declare
                        Held : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree,
                             Syn.Repeated_Element (Of_Tree, Value), Scope);
                     begin
                        if Current = IR.No_Block then
                           return;
                        end if;
                        IR.Emit_Array_Fill
                          (Unit.all, Filling, Destination, 1, Held, Site,
                           Field => Field, Nested => Path,
                           Variant_Case => Variant_Case,
                           Variant_Payload_Field => Variant_Payload_Field);
                     end;
                  elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
                     if Variant_Payload_Field = 0 then
                        IR.Emit_Array_Clear
                          (Unit.all, Filling, Destination, Site,
                           Field => Field, Nested => Path);
                     end if;
                  else
                     --  D20/D50: a whole array source is storage, optionally
                     --  qualified by its containing aggregate field.
                     declare
                        Source_Place : constant IR.Storage :=
                          Rooted_Storage (Of_Tree, Value);
                        Source_Field : constant Natural :=
                          Rooted_Base (Of_Tree, Value);
                        Source_Steps : constant IR.Path_Step_Array :=
                          Rooted_Steps (Of_Tree, Value);
                     begin
                        IR.Emit_Array_Copy
                          (Unit.all, Filling,
                           Source => Source_Place,
                           Destination => Destination,
                           Site => Site,
                           Source_Field => Source_Field,
                           Source_Nested => Source_Steps,
                           Destination_Field => Field,
                           Destination_Nested => Path,
                           Destination_Variant_Case => Variant_Case,
                           Destination_Variant_Payload_Field =>
                             Variant_Payload_Field);
                     end;
                  end if;
               end Write_Array_Value;

               procedure Write_Variant_Value
                 (Value       : Syn.Node_Id;
                  Wrote       : Landin.Checking.Nominal_Type_Id;
                  Field       : Positive;
                  Destination : IR.Storage;
                  Base        : Positive;
                  Steps       : IR.Path_Step_Array := IR.No_Path_Steps)
               is
                  Which : constant Positive := Positive
                    (Landin.Checking.Field_Index
                       (Types.all, Of_Tree, Value));
               begin
                  --  Selecting first clears the complete padded part, so
                  --  omitted scalar leaves, fixed-array zero payloads and
                  --  every inactive byte have [0540]'s zero image before
                  --  labelled scalar expressions are committed.
                  IR.Emit_Variant_Select
                    (Unit.all, Filling, Destination, Base, Which, Site,
                     Nested => Steps);

                  if not Is_Case_Construction (Of_Tree, Value) then
                     return;
                  end if;

                  for Position in
                    1 .. Construction_Field_Count (Of_Tree, Value)
                  loop
                     declare
                        Label : constant Syn.Node_Id :=
                          Nth_Construction_Field (Of_Tree, Value, Position);
                        Payload_Field : constant Positive := Positive
                          (Landin.Checking.Field_Index
                             (Types.all, Of_Tree, Label));
                        Shape : constant Landin.Checking.Field_Shape :=
                          Landin.Checking.Nth_Variant_Case_Field
                            (Types.all, Wrote, Field, Which,
                             Payload_Field);
                     begin
                        case Shape.Kind is
                           when Landin.Checking.Scalar_Field =>
                              declare
                                 Held : constant IR.Value_Id :=
                                   Lower_Expression
                                     (Of_Tree,
                                      Construction_Field_Value
                                        (Of_Tree, Label), Scope);
                              begin
                                 if Current /= IR.No_Block then
                                    IR.Emit_Variant_Field_Store
                                      (Unit.all, Filling, Destination,
                                       Base, Which, Payload_Field, Held,
                                       Site, Nested => Steps);
                                 end if;
                              end;

                           when Landin.Checking.Fixed_Array_Field =>
                              --  D84 writes the same contextual array forms
                              --  as an ordinary field.  A zero payload is a
                              --  no-op because selecting the case cleared the
                              --  complete padded part before any label ran.
                              Write_Array_Value
                                (Construction_Field_Value
                                   (Of_Tree, Label), Destination,
                                 Base, Path => Steps,
                                 Variant_Case => Which,
                                 Variant_Payload_Field => Payload_Field);

                           when Landin.Checking.Aggregate_Field =>
                              --  D120: the payload is a place like any
                              --  other, and the case it sits in is one
                              --  step of the run that reaches it.
                              declare
                                 Child : constant
                                   Landin.Checking.Nominal_Type_Id :=
                                   Shape.Nominal;
                                 Into_Steps :
                                   constant IR.Path_Step_Array :=
                                     Payload_Steps
                                       (Steps, Which, Payload_Field);
                                 Given : constant Syn.Node_Id :=
                                   Construction_Field_Value
                                     (Of_Tree, Label);
                              begin
                                 if Is_Struct_Construction (Of_Tree, Given)
                                 then
                                    Write_Struct_Literal
                                      (Given, Child, Destination,
                                       Base  => Base,
                                       Steps => Into_Steps);
                                 elsif Syn.Kind (Of_Tree, Given)
                                         = Syn.Zeroed_Literal
                                 then
                                    --  Selecting the case already cleared
                                    --  the complete padded part, so an
                                    --  all-zero payload is nothing to do.
                                    null;
                                 else
                                    declare
                                       Source_Base : constant Natural :=
                                         Rooted_Base (Of_Tree, Given);
                                       Source_Steps :
                                         constant IR.Path_Step_Array :=
                                           Rooted_Steps (Of_Tree, Given);
                                       Source : constant IR.Storage :=
                                         Rooted_Storage (Of_Tree, Given);
                                    begin
                                       for Part in
                                         1 .. Landin.Checking
                                                .Layout_Field_Count
                                                  (Types.all, Child)
                                       loop
                                          Copy_Field
                                            (Child, Source, Destination,
                                             Part,
                                             Source_Base => Source_Base,
                                             Source_Steps => Source_Steps,
                                             Destination_Base => Base,
                                             Destination_Steps =>
                                               Into_Steps);
                                       end loop;
                                    end;
                                 end if;
                              end;

                           when Landin.Checking.Variant_Field =>
                              raise Landin.Compiler_Defect with
                                "a nested variant payload reached lowering";
                        end case;
                        exit when Current = IR.No_Block;
                     end;
                  end loop;
               end Write_Variant_Value;

               procedure Write_Struct_Literal
                 (Literal     : Syn.Node_Id;
                  Wrote       : Landin.Checking.Nominal_Type_Id;
                  Destination : IR.Storage;
                  Base        : Natural := 0;
                  Steps       : IR.Path_Step_Array := IR.No_Path_Steps)
               is
                  Count : constant Natural :=
                    Landin.Checking.Layout_Field_Count
                      (Types.all, Wrote);
                  type Seen_Array is array (Positive range <>) of Boolean;
                  Seen : Seen_Array (1 .. Count) := [others => False];

                  procedure Store_Scalar
                    (Field : Positive; Value : IR.Value_Id);

                  procedure Store_Scalar
                    (Field : Positive; Value : IR.Value_Id)
                  is
                     Into_Field : constant Natural :=
                       Descended_Base (Base, Steps, Field);
                     Into_Steps : constant IR.Path_Step_Array :=
                       Descended_Steps (Base, Steps, Field);
                  begin
                     --  D127: a field operation names one part, so a run
                     --  that starts at whole array storage gives its first
                     --  step to the part it names.
                     case Destination.Kind is
                        when IR.Module_Datum =>
                           IR.Emit_Store_Field
                             (Unit.all, Filling, Destination.Datum,
                              Leaf_Base (Into_Field, Into_Steps),
                              Value, Site,
                              Nested =>
                                Leaf_Steps (Into_Field, Into_Steps));
                        when IR.Frame_Slot =>
                           IR.Emit_Store_Slot_Field
                             (Unit.all, Filling, Destination.Slot,
                              Leaf_Base (Into_Field, Into_Steps),
                              Value, Site,
                              Nested =>
                                Leaf_Steps (Into_Field, Into_Steps));
                        when IR.Runtime_Address =>
                           raise Landin.Compiler_Defect with
                             "a runtime literal destination was not"
                             & " temporary-backed";
                     end case;
                  end Store_Scalar;
               begin
                  --  [0410]/D29: named fields are evaluated and committed in
                  --  source order, irrespective of declaration/layout order.
                  for Position in
                    1 .. Construction_Field_Count (Of_Tree, Literal)
                  loop
                     declare
                        Field_Node : constant Syn.Node_Id :=
                          Nth_Construction_Field
                            (Of_Tree, Literal, Position);
                        Field : constant Natural :=
                          Landin.Checking.Field_Index
                            (Types.all, Of_Tree, Field_Node);
                        Value : constant Syn.Node_Id :=
                          Construction_Field_Value (Of_Tree, Field_Node);
                     begin
                        pragma Assert (Field > 0);
                        Seen (Field) := True;
                        case Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Field)
                        is
                           when Landin.Checking.Scalar_Field =>
                              declare
                                 Held : constant IR.Value_Id :=
                                   Lower_Expression
                                     (Of_Tree, Value, Scope);
                              begin
                                 if Current /= IR.No_Block then
                                    Store_Scalar (Field, Held);
                                 end if;
                              end;
                           when Landin.Checking.Fixed_Array_Field =>
                              --  D65: the label is the same contextual array
                              --  destination D49--D53 lower on assignment.
                              Write_Array_Value
                                (Value, Destination,
                                 Descended_Base (Base, Steps, Field),
                                 Path =>
                                   Descended_Steps (Base, Steps, Field));

                           when Landin.Checking.Aggregate_Field =>
                              declare
                                 Child : constant
                                   Landin.Checking.Nominal_Type_Id :=
                                   Landin.Checking.Field_Shape_Of
                                     (Types.all, Wrote, Field).Nominal;
                                 Into_Field : constant Natural :=
                                   Descended_Base (Base, Steps, Field);
                                 Into_Steps :
                                   constant IR.Path_Step_Array :=
                                     Descended_Steps (Base, Steps, Field);
                              begin
                                 if Is_Struct_Construction (Of_Tree, Value)
                                 then
                                    Write_Struct_Literal
                                      (Value, Child, Destination,
                                       Base  => Into_Field,
                                       Steps => Into_Steps);
                                 elsif Syn.Kind (Of_Tree, Value)
                                         = Syn.Zeroed_Literal
                                 then
                                    IR.Emit_Array_Clear
                                      (Unit.all, Filling, Destination, Site,
                                       Field  => Into_Field,
                                       Nested => Into_Steps);
                                 else
                                    declare
                                       Source_Base : constant Natural :=
                                         Rooted_Base (Of_Tree, Value);
                                       Source_Steps :
                                         constant IR.Path_Step_Array :=
                                           Rooted_Steps (Of_Tree, Value);
                                       Source : constant IR.Storage :=
                                         Rooted_Storage (Of_Tree, Value);
                                    begin
                                       for Child_Field in
                                         1 .. Landin.Checking
                                                .Layout_Field_Count
                                                  (Types.all, Child)
                                       loop
                                          Copy_Field
                                            (Child, Source, Destination,
                                             Child_Field,
                                             Source_Base => Source_Base,
                                             Source_Steps => Source_Steps,
                                             Destination_Base => Into_Field,
                                             Destination_Steps =>
                                               Into_Steps);
                                       end loop;
                                    end;
                                 end if;
                              end;

                           when Landin.Checking.Variant_Field =>
                              --  D126: a labelled variant part is one
                              --  place deeper, like every other label.
                              Write_Variant_Value
                                (Value, Wrote, Field, Destination,
                                 Base  => Descended_Base (Base, Steps, Field),
                                 Steps =>
                                   Descended_Steps (Base, Steps, Field));
                        end case;
                        exit when Current = IR.No_Block;
                     end;
                  end loop;

                  if Current = IR.No_Block then
                     return;
                  end if;

                  --  D64's deliberately narrow fill is all-bits zero.  It is
                  --  written after every labelled value, in declaration
                  --  order, without forming one heterogeneously typed value.
                  if Construction_Fill (Of_Tree, Literal) /= Syn.No_Node then
                     for Field in Seen'Range loop
                        if not Seen (Field) then
                           case Landin.Checking.Field_Kind_Of
                             (Types.all, Wrote, Field)
                           is
                              when Landin.Checking.Scalar_Field =>
                                 declare
                                    Held : constant Ty.Scalar_Name :=
                                      Landin.Checking.Field_Type
                                        (Types.all, Wrote, Field);
                                    Zero : IR.Value_Id;
                                 begin
                                    if Held = Ty.Bool then
                                       Zero := IR.Emit_Truth
                                         (Unit.all, Filling, False, Site);
                                    else
                                       Zero := IR.Emit_Number
                                         (Unit.all, Filling, Held, 0, False,
                                          Site);
                                    end if;
                                    Store_Scalar (Field, Zero);
                                 end;

                              when Landin.Checking.Fixed_Array_Field
                                 | Landin.Checking.Aggregate_Field =>
                                 --  One whole-part clear covers both: a
                                 --  fixed array's elements and a child's
                                 --  complete padded extent are the same
                                 --  all-bits-zero image [0540].
                                 IR.Emit_Array_Clear
                                   (Unit.all, Filling, Destination, Site,
                                    Field  =>
                                      Descended_Base (Base, Steps, Field),
                                    Nested =>
                                      Descended_Steps (Base, Steps, Field));

                              when Landin.Checking.Variant_Field =>
                                 --  D75's zero image selects the first case.
                                 IR.Emit_Variant_Select
                                   (Unit.all, Filling, Destination,
                                    Descended_Base (Base, Steps, Field),
                                    1, Site,
                                    Nested =>
                                      Descended_Steps (Base, Steps, Field));
                           end case;
                        end if;
                     end loop;
                  end if;
               end Write_Struct_Literal;

               function Index_For (Place : Syn.Node_Id) return IR.Value_Id is
               begin
                  if Syn.Kind (Of_Tree, Place) /= Syn.Element_Index
                    or else
                      (Is_Constant_Index (Of_Tree, Place)
                       and then Syn.Kind
                                  (Of_Tree, Syn.Target_Of (Of_Tree, Place))
                                /= Syn.Member_Selection
                       and then not Aliases
                         (Declared
                            (Res.Bound_To
                               (Meanings.all, Of_Tree,
                                Syn.Target_Of (Of_Tree, Place)))).Active)
                  then
                     return IR.No_Value;
                  end if;

                  return Lower_Expression
                           (Of_Tree, Syn.Index_Of (Of_Tree, Place), Scope);
               end Index_For;

               function Read_Place
                 (Place : Syn.Node_Id; Index : IR.Value_Id)
                  return IR.Value_Id
               is
                  From : constant Syn.Node_Id :=
                    (if Index = IR.No_Value then Syn.No_Node
                     else Syn.Target_Of (Of_Tree, Place));
                  Named : constant Syn.Node_Id :=
                    (if From = Syn.No_Node then Syn.No_Node
                     else Chain_Root (Of_Tree, Chain_Above (Of_Tree, From)));
                  Field : constant Natural :=
                    (if From = Syn.No_Node then 0
                     else Chain_Base (Of_Tree, Chain_Above (Of_Tree, From)));
                  Child_Steps : constant IR.Path_Step_Array :=
                    (if From = Syn.No_Node then IR.No_Path_Steps
                     else Chain_Steps
                       (Of_Tree, Chain_Above (Of_Tree, From)));
                  Means : Res.Declaration_Id;
               begin
                  if Index = IR.No_Value then
                     return Lower_Expression (Of_Tree, Place, Scope);
                  end if;

                  Means := Res.Bound_To (Meanings.all, Of_Tree, Named);
                  if Aliases (Declared (Means)).Active then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                     begin
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive array match binding reached"
                             & " lowering";
                        end if;
                        case Alias.Source.Kind is
                           when IR.Module_Datum =>
                              return IR.Emit_Load_Element
                                (Unit.all, Filling, Alias.Source.Datum,
                                 Index, Scalar_At (Of_Tree, Place), Site,
                                 Field => Alias.Field,
                                 Nested => Alias_Steps (Of_Tree, Alias),
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Alias.Source.Slot,
                                 Index, Scalar_At (Of_Tree, Place), Site,
                                 Field => Alias.Field,
                                 Nested => Alias_Steps (Of_Tree, Alias),
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "a runtime array alias reached scalar read";
                        end case;
                     end;
                  end if;
                  if Res.Sort_Of (Meanings.all, Means) = Res.Local_Binding
                  then
                     return IR.Emit_Load_Slot_Element
                              (Unit.all, Filling,
                               Slot_For (Of_Tree, Named, Means),
                               Index, Scalar_At (Of_Tree, Place), Site,
                               Field => Field, Nested => Child_Steps);
                  end if;

                  return IR.Emit_Load_Element
                           (Unit.all, Filling, IR.Item_For (Unit.all, Means),
                            Index, Scalar_At (Of_Tree, Place), Site,
                            Field => Field, Nested => Child_Steps);
               end Read_Place;

               procedure Write
                 (Place : Syn.Node_Id;
                  Value : IR.Value_Id;
                  Index : IR.Value_Id := IR.No_Value)
               is
                  --  [1810]'s place is [1820]'s selection, so a field is
                  --  written where the binding holding it is named.
                  Selected : constant Syn.Node_Id :=
                    (if Syn.Kind (Of_Tree, Place) = Syn.Element_Index
                     then Syn.Target_Of (Of_Tree, Place)
                     else Place);
                  --  D121: the chain may pass through an index, and the
                  --  name it started from is above that.
                  Named : constant Syn.Node_Id :=
                    Chain_Root (Of_Tree, Chain_Above (Of_Tree, Selected));
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Named);
               begin
                  --  D120: an alias for an ordinary-struct payload is not
                  --  a payload leaf; a field of it is written the way a
                  --  field of any other storage is, through the run that
                  --  reaches it.
                  if Aliases (Declared (Means)).Active
                    and then Syn.Kind (Of_Tree, Place)
                      /= Syn.Member_Selection
                    and then not Roots_At_An_Aggregate_Alias
                      (Of_Tree, Selected)
                  then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                     begin
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive match binding reached lowering";
                        end if;
                        if Alias.Which = 0 then
                           if Syn.Kind (Of_Tree, Place) = Syn.Element_Index
                           then
                              pragma Assert (Index /= IR.No_Value);
                              case Alias.Source.Kind is
                                 when IR.Module_Datum =>
                                    IR.Emit_Store_Element
                                      (Unit.all, Filling,
                                       Alias.Source.Datum, Index, Value, Site,
                                       Field => Alias.Field);
                                 when IR.Frame_Slot =>
                                    IR.Emit_Store_Slot_Element
                                      (Unit.all, Filling,
                                       Alias.Source.Slot, Index, Value, Site,
                                       Field => Alias.Field);
                                 when IR.Runtime_Address =>
                                    raise Landin.Compiler_Defect with
                                      "a runtime alias reached scalar write";
                              end case;
                           else
                              case Alias.Source.Kind is
                                 when IR.Module_Datum =>
                                    IR.Emit_Store_Field
                                      (Unit.all, Filling,
                                       Alias.Source.Datum,
                                       IR.Part_Position (Alias.Field),
                                       Value, Site);
                                 when IR.Frame_Slot =>
                                    IR.Emit_Store_Slot_Field
                                      (Unit.all, Filling,
                                       Alias.Source.Slot,
                                       IR.Part_Position (Alias.Field),
                                       Value, Site);
                                 when IR.Runtime_Address =>
                                    raise Landin.Compiler_Defect with
                                      "a runtime alias reached scalar write";
                              end case;
                           end if;
                        elsif Syn.Kind (Of_Tree, Place)
                                = Syn.Element_Index
                        then
                           pragma Assert (Index /= IR.No_Value);
                           case Alias.Source.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Element
                                   (Unit.all, Filling, Alias.Source.Datum,
                                    Index, Value, Site,
                                    Field => Alias.Field,
                                    Nested => Alias_Steps (Of_Tree, Alias),
                                    Variant_Case => Alias.Which,
                                    Variant_Payload_Field =>
                                      Alias.Payload_Field);
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Element
                                   (Unit.all, Filling, Alias.Source.Slot,
                                    Index, Value, Site,
                                    Field => Alias.Field,
                                    Nested => Alias_Steps (Of_Tree, Alias),
                                    Variant_Case => Alias.Which,
                                    Variant_Payload_Field =>
                                      Alias.Payload_Field);
                              when IR.Runtime_Address =>
                                 raise Landin.Compiler_Defect with
                                   "a runtime alias reached scalar write";
                           end case;
                        else
                           IR.Emit_Variant_Field_Store
                             (Unit.all, Filling, Alias.Source,
                              Positive (Alias.Field),
                              Positive (Alias.Which),
                              Positive (Alias.Payload_Field), Value, Site,
                              Nested => Alias_Steps (Of_Tree, Alias));
                        end if;
                        return;
                     end;
                  end if;

                  if Syn.Kind (Of_Tree, Place) = Syn.Element_Index then
                     declare
                        Field : constant Natural :=
                          Chain_Base (Of_Tree, Selected);
                        Child_Steps : constant IR.Path_Step_Array :=
                          Chain_Steps (Of_Tree, Selected);
                     begin
                        if Res.Sort_Of (Meanings.all, Means)
                           = Res.Local_Binding
                        then
                           if Index = IR.No_Value then
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling,
                                 Slot_For (Of_Tree, Named, Means),
                                 Constant_Index (Of_Tree, Place),
                                 Value, Site);
                           else
                              IR.Emit_Store_Slot_Element
                                (Unit.all, Filling,
                                 Slot_For (Of_Tree, Named, Means),
                                 Index, Value, Site, Field => Field,
                                 Nested => Child_Steps);
                           end if;
                        elsif Index = IR.No_Value then
                           IR.Emit_Store_Field
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means),
                              Constant_Index (Of_Tree, Place), Value, Site);
                        else
                           IR.Emit_Store_Element
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means),
                              Index, Value, Site, Field => Field,
                              Nested => Child_Steps);
                        end if;
                     end;
                     return;
                  end if;

                  if Syn.Kind (Of_Tree, Place) = Syn.Member_Selection then
                     declare
                        Indexed : constant Syn.Node_Id :=
                          Chain_Index (Of_Tree, Place);
                        Above : constant Syn.Node_Id :=
                          Chain_Above (Of_Tree, Place);
                        Into : constant IR.Storage :=
                          Rooted_Storage (Of_Tree, Above);
                        --  Zero when the array is a name of its own,
                        --  which is not a field position at all.
                        Base : constant Natural :=
                          Rooted_Base (Of_Tree, Above);
                        Child_Steps : constant IR.Path_Step_Array :=
                          Rooted_Steps (Of_Tree, Above);
                        Below : constant IR.Path_Step_Array :=
                          Chain_Below (Of_Tree, Place);
                     begin
                        --  D121: writing a leaf inside an element is the
                        --  same element operation, with the run inside
                        --  the element after the index.
                        if Indexed /= Syn.No_Node then
                           declare
                              At_Index : constant IR.Value_Id :=
                                Lower_Expression
                                  (Of_Tree,
                                   Syn.Index_Of (Of_Tree, Indexed), Scope);
                           begin
                              case Into.Kind is
                                 when IR.Module_Datum =>
                                    IR.Emit_Store_Element
                                      (Unit.all, Filling, Into.Datum,
                                       At_Index, Value, Site,
                                       Field  => Base,
                                       Nested => Child_Steps,
                                       Below  => Below);
                                 when IR.Frame_Slot =>
                                    IR.Emit_Store_Slot_Element
                                      (Unit.all, Filling, Into.Slot,
                                       At_Index, Value, Site,
                                       Field  => Base,
                                       Nested => Child_Steps,
                                       Below  => Below);
                                 when IR.Runtime_Address =>
                                    raise Landin.Compiler_Defect with
                                      "a second computed index reached"
                                      & " scalar write";
                              end case;
                           end;
                           return;
                        end if;

                        case Into.Kind is
                           when IR.Module_Datum =>
                              IR.Emit_Store_Field
                                (Unit.all, Filling, Into.Datum,
                                 Leaf_Base (Base, Child_Steps),
                                 Value, Site,
                                 Nested => Leaf_Steps (Base, Child_Steps));
                           when IR.Frame_Slot =>
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling, Into.Slot,
                                 Leaf_Base (Base, Child_Steps),
                                 Value, Site,
                                 Nested => Leaf_Steps (Base, Child_Steps));
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "a runtime address reached scalar write";
                        end case;
                     end;

                     return;
                  end if;

                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Module_Binding
                  then
                     IR.Emit_Store_Datum
                       (Unit.all, Filling,
                        IR.Item_For (Unit.all, Means), Value, Site);
                  else
                     IR.Emit_Store
                       (Unit.all, Filling,
                        Slot_For (Of_Tree, Place, Means), Value, Site);
                  end if;
               end Write;

            begin
               if Final_Value then
                  declare
                     Held : constant Ty.Type_Kind := Type_At (Of_Tree, Stmt);
                     Target : IR.Slot_Id := Destination;
                  begin
                     if Held in Ty.Aggregate | Ty.Fixed_Array
                       and then Target = IR.No_Slot
                     then
                        if Held = Ty.Aggregate then
                           declare
                              Wrote : constant
                                Landin.Checking.Nominal_Type_Id :=
                                Landin.Checking.Nominal_Of
                                  (Types.all, Of_Tree, Stmt);
                              Shape : constant
                                Landin.Checking.Signature_Id :=
                                  Landin.Checking.Result_Shape_Of
                                    (Types.all, Of_Tree, Stmt);
                           begin
                              Target := IR.Add_Aggregate_Slot
                                (Unit.all, Filling, Res.No_Declaration, Site,
                                 (if Shape = Landin.Checking.No_Signature
                                  then Nominal_For (Wrote)
                                  else IR.No_Nominal_Type));
                              if Shape /= Landin.Checking.No_Signature then
                                 Add_Result_Fields (Shape, Slot => Target);
                              else
                                 for Field in
                                   1 .. Landin.Checking.Layout_Field_Count
                                          (Types.all, Wrote)
                                 loop
                                    Add_Stored_Field
                                      (Wrote, Field, Slot => Target);
                                 end loop;
                              end if;
                           end;
                        else
                           Target := IR.Add_Array_Slot
                             (Unit.all, Filling,
                              Neutral_Element (Of_Tree, Stmt),
                              IR.Element_Total
                                (Landin.Checking.Array_Length
                                   (Types.all, Of_Tree, Stmt)),
                              Res.No_Declaration, Site);
                        end if;
                     end if;

                     if Held = Ty.No_Value
                       and then Syn.Kind (Of_Tree, Stmt) = Syn.Call
                     then
                        --  Calls overlap statement and expression syntax.
                        --  The parser can only know that a final call is the
                        --  last item in this block; checking is what learns
                        --  that it returns none.  Lower it as the statement
                        --  it therefore is instead of asking it to fill the
                        --  block's optional destination.
                        declare
                           Ignored : constant IR.Value_Id :=
                             Lower_Call (Of_Tree, Stmt, Scope);
                        begin
                           pragma Unreferenced (Ignored);
                        end;
                     elsif Held in
                       Ty.Scalar_Name | Ty.Function_Value | Ty.Atom_Value
                     then
                        declare
                           Ignored : constant IR.Value_Id :=
                             Lower_Expression (Of_Tree, Stmt, Scope);
                        begin
                           if Current /= IR.No_Block
                             and then Destination /= IR.No_Slot
                           then
                              IR.Emit_Store
                                (Unit.all, Filling, Destination, Ignored,
                                 Site);
                           end if;
                        end;
                     elsif Syn.Kind (Of_Tree, Stmt) = Syn.If_Statement then
                        Lower_If
                          (Of_Tree, Stmt, Scope, Result, Target,
                           Destination_Field, Destination_Path);
                     elsif Syn.Kind (Of_Tree, Stmt)
                             = Syn.Match_Statement
                     then
                        Lower_Match
                          (Of_Tree, Stmt, Scope, Result, Target,
                           Destination_Field, Destination_Path);
                     elsif Syn.Kind (Of_Tree, Stmt) = Syn.Bare_Block then
                        Lower_Bare_Block
                          (Of_Tree, Stmt, Scope, Result, Target,
                           Destination_Field, Destination_Path);
                     elsif Syn.Kind (Of_Tree, Stmt)
                             in Syn.Call | Syn.Try_Expression
                     then
                        Lower_Stored_Expression
                          (Of_Tree, Stmt, Scope, Target,
                           Destination_Field, Destination_Path);
                     elsif Held = Ty.Fixed_Array then
                        Write_Array_Value
                          (Stmt, (Kind => IR.Frame_Slot, Slot => Target),
                           Destination_Field, Path => Destination_Path);
                     elsif Held = Ty.Aggregate
                       and then Is_Struct_Construction (Of_Tree, Stmt)
                     then
                        Write_Struct_Literal
                          (Stmt,
                           Landin.Checking.Nominal_Of
                             (Types.all, Of_Tree, Stmt),
                           (Kind => IR.Frame_Slot, Slot => Target),
                           Base => Destination_Field,
                           Steps => Destination_Path);
                     elsif Held = Ty.Aggregate
                       and then Syn.Kind (Of_Tree, Stmt)
                                  = Syn.Zeroed_Literal
                     then
                        IR.Emit_Array_Clear
                          (Unit.all, Filling,
                           (Kind => IR.Frame_Slot, Slot => Target), Site,
                           Field => Destination_Field,
                           Nested => Destination_Path);
                     elsif Held = Ty.Aggregate then
                        declare
                           Shape : constant Landin.Checking.Signature_Id :=
                             Landin.Checking.Result_Shape_Of
                               (Types.all, Of_Tree, Stmt);
                           Wrote : constant Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Nominal_Of
                               (Types.all, Of_Tree, Stmt);
                           Target_Storage : constant IR.Storage :=
                             (Kind => IR.Frame_Slot, Slot => Target);
                        begin
                           if Shape /= Landin.Checking.No_Signature then
                              declare
                                 Source : constant IR.Storage :=
                                   Rooted_Storage (Of_Tree, Stmt);
                              begin
                                 for Field in
                                   1 .. Landin.Checking
                                          .Signature_Result_Count
                                            (Types.all, Shape)
                                 loop
                                    Copy_Result_Field
                                      (Shape, Source, Target_Storage, Field);
                                 end loop;
                              end;
                           else
                              Copy_Aggregate_Value
                                (Wrote, Stmt, Target_Storage,
                                 Destination_Base => Destination_Field,
                                 Destination_Steps => Destination_Path);
                           end if;
                        end;
                     else
                        raise Landin.Compiler_Defect with
                          "a block value has no lowerable shape";
                     end if;
                  end;
               else
                  case Syn.Kind (Of_Tree, Stmt) is
                  when Syn.Binding =>
                     declare
                        Id : constant Res.Declaration_Id :=
                          Declaration_At (Syn.Source_Of (Of_Tree), Stmt);
                        Where : constant IR.Slot_Id :=
                          Slot_For (Of_Tree, Stmt, Id);
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Stmt);
                     begin
                        if Value = Syn.No_Node then
                           null;
                        elsif Landin.Checking.Type_Of (Types.all, Id)
                                = Ty.Fixed_Array
                        then
                           if Syn.Kind (Of_Tree, Value)
                                in Syn.If_Statement | Syn.Match_Statement
                                   | Syn.Bare_Block
                           then
                              case Syn.Kind (Of_Tree, Value) is
                                 when Syn.If_Statement =>
                                    Lower_If
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when Syn.Match_Statement =>
                                    Lower_Match
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when Syn.Bare_Block =>
                                    Lower_Bare_Block
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when others =>
                                    raise Landin.Compiler_Defect;
                              end case;
                           elsif Syn.Kind (Of_Tree, Value)
                                   in Syn.Call | Syn.Try_Expression
                           then
                              Lower_Stored_Expression
                                (Of_Tree, Value, Scope, Where);
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Literal
                           then
                              --  D23/D25: a literal has exactly the finite
                              --  element run the source wrote.  Lower and
                              --  store each one immediately, preserving
                              --  [0410]'s left-to-right evaluation in the
                              --  existing compact array slot.
                              for Position in
                                1 .. Syn.Element_Count (Of_Tree, Value)
                              loop
                                 declare
                                    Held : constant IR.Value_Id :=
                                      Lower_Expression
                                        (Of_Tree,
                                         Syn.Nth_Element
                                           (Of_Tree, Value, Position),
                                         Scope);
                                 begin
                                    exit when Current = IR.No_Block;
                                    IR.Emit_Store_Slot_Field
                                      (Unit.all, Filling, Where,
                                       IR.Part_Position (Position), Held,
                                       Site);
                                 end;
                              end loop;
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Mixed_Array_Repetition
                           then
                              --  D36 stores the prefix as it is evaluated,
                              --  then evaluates one suffix pattern and fills
                              --  from the first part after that prefix.
                              for Position in
                                1 .. Syn.Element_Count (Of_Tree, Value)
                              loop
                                 declare
                                    Held : constant IR.Value_Id :=
                                      Lower_Expression
                                        (Of_Tree,
                                         Syn.Nth_Element
                                           (Of_Tree, Value, Position),
                                         Scope);
                                 begin
                                    exit when Current = IR.No_Block;
                                    IR.Emit_Store_Slot_Field
                                      (Unit.all, Filling, Where,
                                       IR.Part_Position (Position), Held,
                                       Site);
                                 end;
                              end loop;

                              if Current /= IR.No_Block then
                                 declare
                                    Held : constant IR.Value_Id :=
                                      Lower_Expression
                                        (Of_Tree,
                                         Syn.Repeated_Element
                                           (Of_Tree, Value), Scope);
                                 begin
                                    if Current /= IR.No_Block then
                                       IR.Emit_Array_Fill
                                         (Unit.all, Filling,
                                          Destination =>
                                            IR.Storage'
                                              (Kind => IR.Frame_Slot,
                                               Slot => Where),
                                          First => IR.Part_Position
                                            (Syn.Element_Count
                                               (Of_Tree, Value) + 1),
                                          Value => Held,
                                          Site  => Site);
                                    end if;
                                 end;
                              end if;
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Repetition
                           then
                              declare
                                 Held : constant IR.Value_Id :=
                                   Lower_Expression
                                     (Of_Tree,
                                      Syn.Repeated_Element (Of_Tree, Value),
                                      Scope);
                              begin
                                 if Current /= IR.No_Block then
                                    IR.Emit_Array_Fill
                                      (Unit.all, Filling,
                                       Destination =>
                                         IR.Storage'
                                           (Kind => IR.Frame_Slot,
                                            Slot => Where),
                                       First => 1, Value => Held,
                                       Site => Site);
                                 end if;
                              end;
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Zeroed_Literal
                           then
                              --  D28: clear the complete compact slot at
                              --  runtime with one extent-independent
                              --  operation.
                              IR.Emit_Array_Clear
                                (Unit.all, Filling,
                                 Destination =>
                                   IR.Storage'
                                     (Kind => IR.Frame_Slot, Slot => Where),
                                 Site        => Site);
                           else
                              --  D21: the initializer copies a whole array
                              --  from storage into this fresh local slot.
                              --  D51 reuses D50's source-field identity when
                              --  that storage is a containing struct; no
                              --  opcode or target offset is introduced.
                              declare
                                 Source_Place : constant IR.Storage :=
                                   Rooted_Storage (Of_Tree, Value);
                                 Source_Field : constant Natural :=
                                   Rooted_Base (Of_Tree, Value);
                                 Source_Steps :
                                   constant IR.Path_Step_Array :=
                                     Rooted_Steps (Of_Tree, Value);
                              begin
                                 IR.Emit_Array_Copy
                                   (Unit.all, Filling,
                                    Source => Source_Place,
                                    Destination =>
                                      IR.Storage'
                                        (Kind => IR.Frame_Slot,
                                         Slot => Where),
                                    Site => Site,
                                    Source_Field => Source_Field,
                                    Source_Nested => Source_Steps);
                              end;
                           end if;
                        elsif Landin.Checking.Type_Of (Types.all, Id)
                                = Ty.Aggregate
                        then
                           if Syn.Kind (Of_Tree, Value)
                                in Syn.If_Statement | Syn.Match_Statement
                                   | Syn.Bare_Block
                           then
                              case Syn.Kind (Of_Tree, Value) is
                                 when Syn.If_Statement =>
                                    Lower_If
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when Syn.Match_Statement =>
                                    Lower_Match
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when Syn.Bare_Block =>
                                    Lower_Bare_Block
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when others =>
                                    raise Landin.Compiler_Defect;
                              end case;
                           elsif Syn.Kind (Of_Tree, Value)
                                   in Syn.Call | Syn.Try_Expression
                           then
                              Lower_Stored_Expression
                                (Of_Tree, Value, Scope, Where);
                           elsif Is_Struct_Construction (Of_Tree, Value) then
                              Write_Struct_Literal
                                (Value,
                                 Landin.Checking.Nominal_Of (Types.all, Id),
                                 (Kind => IR.Frame_Slot, Slot => Where));
                           elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Zeroed_Literal
                           then
                              --  D57: one whole-storage clear writes the
                              --  complete padded image of the fresh aggregate
                              --  slot; field zero identifies the whole cell.
                              IR.Emit_Array_Clear
                                (Unit.all, Filling,
                                 Destination =>
                                   IR.Storage'
                                     (Kind => IR.Frame_Slot, Slot => Where),
                                 Site => Site);
                           else
                              --  D55 copies a nominal aggregate field by
                              --  field.  D128 applies the same rule to the
                              --  ordered fields of an anonymous result shape.
                              declare
                                 Shape : constant
                                   Landin.Checking.Signature_Id :=
                                     Landin.Checking.Result_Shape_Of
                                       (Types.all, Id);
                                 Wrote : constant
                                   Landin.Checking.Nominal_Type_Id :=
                                   Landin.Checking.Nominal_Of (Types.all, Id);
                                 Destination : constant IR.Storage :=
                                   (Kind => IR.Frame_Slot, Slot => Where);
                              begin
                                 if Shape /= Landin.Checking.No_Signature then
                                    declare
                                       Source : constant IR.Storage :=
                                         Rooted_Storage (Of_Tree, Value);
                                    begin
                                       for Field in
                                         1 .. Landin.Checking
                                                .Signature_Result_Count
                                                  (Types.all, Shape)
                                       loop
                                          Copy_Result_Field
                                            (Shape, Source, Destination,
                                             Field);
                                       end loop;
                                    end;
                                 else
                                    Copy_Aggregate_Value
                                      (Wrote, Value, Destination);
                                 end if;
                              end;
                           end if;
                        else
                           declare
                              Held : constant IR.Value_Id :=
                                Lower_Expression
                                  (Of_Tree, Value, Scope);
                           begin
                              if Current /= IR.No_Block then
                                 IR.Emit_Store
                                   (Unit.all, Filling, Where, Held, Site);
                              end if;
                           end;
                        end if;
                     end;

                  when Syn.Destructuring_Binding =>
                     declare
                        Value : constant Syn.Node_Id :=
                          Syn.Destructured_Value (Of_Tree, Stmt);
                        Source : IR.Storage;
                        Temporary : IR.Slot_Id := IR.No_Slot;
                     begin
                        if Syn.Kind (Of_Tree, Value)
                             in Syn.Call | Syn.If_Statement
                                | Syn.Match_Statement | Syn.Bare_Block
                        then
                           Temporary := Add_Value_Temporary (Of_Tree, Value);
                           Lower_Stored_Expression
                             (Of_Tree, Value, Scope, Temporary);
                           Source :=
                             (Kind => IR.Frame_Slot, Slot => Temporary);
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Name_Reference
                        then
                           Source := Storage_For (Of_Tree, Value);
                        else
                           raise Landin.Compiler_Defect with
                             "a checked result destructure has no storage";
                        end if;

                        if Current /= IR.No_Block then
                           for Position in
                             1 .. Syn.Destructured_Field_Count
                                    (Of_Tree, Stmt)
                           loop
                              declare
                                 Field : constant Syn.Node_Id :=
                                   Syn.Nth_Destructured_Field
                                     (Of_Tree, Stmt, Position);
                              begin
                                 if Syn.Kind (Of_Tree, Field)
                                      = Syn.Destructured_Field
                                   and then Syn.Destructured_Local
                                     (Of_Tree, Field) /= Syn.No_Node
                                 then
                                    declare
                                       Local : constant Syn.Node_Id :=
                                         Syn.Destructured_Local
                                           (Of_Tree, Field);
                                       Id : constant Res.Declaration_Id :=
                                         Declaration_At
                                           (Syn.Source_Of (Of_Tree), Local);
                                    begin
                                       Aliases (Declared (Id)) :=
                                         (Active        => True,
                                          Source        => Source,
                                          Field         =>
                                            Landin.Checking.Field_Index
                                              (Types.all, Of_Tree, Field),
                                          Subject       => Syn.No_Node,
                                          Which         => 0,
                                          Payload_Field => 0);
                                    end;
                                 end if;
                              end;
                           end loop;
                        end if;
                     end;

                  when Syn.Assignment =>
                     --  D76's direct part assignment is contextual and its
                     --  target is Not_Typed rather than a general aggregate
                     --  value.  Lower it before the ordinary whole-struct
                     --  branch asks the place for an aggregate body.
                     if Syn.Kind
                          (Of_Tree, Syn.Target_Of (Of_Tree, Stmt))
                          = Syn.Member_Selection
                       and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree,
                          Syn.Target_Of (Of_Tree, Stmt)) = Ty.Not_Typed
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           --  D126: the variant part may sit below the
                           --  name; Wrote is the body that declares it and
                           --  Base/Steps is the run that reaches it.
                           Holder : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Place);
                           Computed : constant Boolean :=
                             Has_Computed_Index (Of_Tree, Holder);
                           Named : constant Syn.Node_Id :=
                             (if Computed then Syn.No_Node
                              else Chain_Root (Of_Tree, Place));
                           Wrote : constant Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Nominal_Of
                               (Types.all, Of_Tree, Holder);
                           Field : constant Positive := Positive
                             (Landin.Checking.Field_Index
                                (Types.all, Of_Tree, Place));
                           --  A computed element is first retained as whole
                           --  holder storage.  A shaped temporary preserves
                           --  every sibling while the ordinary variant
                           --  operation evaluates its payload in source order.
                           Reached : constant Natural :=
                             (if Computed then 0
                              else Chain_Base (Of_Tree, Place));
                           Walked : constant IR.Path_Step_Array :=
                             (if Computed then IR.No_Path_Steps
                              else Chain_Steps (Of_Tree, Place));
                           Base : constant Positive :=
                             (if Computed then Field
                              else Positive (Leaf_Base (Reached, Walked)));
                           Steps : constant IR.Path_Step_Array :=
                             (if Computed then IR.No_Path_Steps
                              else Leaf_Steps (Reached, Walked));
                        begin
                           pragma Assert
                             (Landin.Checking.Field_Kind_Of
                                (Types.all, Wrote, Field)
                                = Landin.Checking.Variant_Field);
                           if Computed then
                              declare
                                 Holder_Place : constant Stored_Place :=
                                   Lower_Stored_Place
                                     (Of_Tree, Holder, Scope);
                              begin
                                 if Current /= IR.No_Block then
                                    declare
                                       Shape : constant IR.Field_Shape :=
                                         Neutral_Body (Wrote);
                                       Into : constant IR.Storage :=
                                         Addressed_Storage
                                           (Holder_Place, Shape, Site);
                                       Temporary : constant IR.Slot_Id :=
                                         IR.Add_Aggregate_Slot
                                           (Unit.all, Filling,
                                            Res.No_Declaration, Site,
                                            Nominal_For (Wrote));
                                       Temp_Storage : constant IR.Storage :=
                                         (Kind => IR.Frame_Slot,
                                          Slot => Temporary);
                                    begin
                                       for Part in
                                         1 .. Landin.Checking
                                                .Layout_Field_Count
                                                  (Types.all, Wrote)
                                       loop
                                          Add_Stored_Field
                                            (Wrote, Part,
                                             Slot => Temporary);
                                       end loop;
                                       declare
                                          Temp : constant Stored_Place :=
                                            (Place => Temp_Storage,
                                             Base => 0,
                                             Steps => Stored_Path_Vectors
                                               .Empty_Vector);
                                          Temp_Address : constant IR.Storage :=
                                            Addressed_Storage
                                              (Temp, Shape, Site);
                                       begin
                                          IR.Emit_Array_Copy
                                            (Unit.all, Filling, Into,
                                             Temp_Address, Site);
                                          Write_Variant_Value
                                            (Syn.Value_Of (Of_Tree, Stmt),
                                             Wrote, Field, Temp_Storage,
                                             Base => Base, Steps => Steps);
                                          if Current /= IR.No_Block then
                                             IR.Emit_Array_Copy
                                               (Unit.all, Filling,
                                                Temp_Address, Into, Site);
                                          end if;
                                       end;
                                    end;
                                 end if;
                              end;
                           else
                              Write_Variant_Value
                                (Syn.Value_Of (Of_Tree, Stmt), Wrote, Field,
                                 Storage_For (Of_Tree, Named),
                                 Base => Base, Steps => Steps);
                           end if;
                        end;

                     --  D128's anonymous result aggregate is structural and
                     --  always occupies one direct inferred local slot.  A
                     --  call or control value constructs there; another whole
                     --  result is copied field by named field.
                     elsif Landin.Checking.Type_Of
                          (Types.all, Of_Tree,
                           Syn.Target_Of (Of_Tree, Stmt)) = Ty.Aggregate
                       and then Landin.Checking.Result_Shape_Of
                         (Types.all, Of_Tree,
                          Syn.Target_Of (Of_Tree, Stmt))
                           /= Landin.Checking.No_Signature
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           From : constant Syn.Node_Id :=
                             Syn.Value_Of (Of_Tree, Stmt);
                           Shape : constant Landin.Checking.Signature_Id :=
                             Landin.Checking.Result_Shape_Of
                               (Types.all, Of_Tree, Place);
                           Destination : constant IR.Storage :=
                             Storage_For (Of_Tree, Place);
                        begin
                           pragma Assert
                             (Destination.Kind = IR.Frame_Slot);
                           if Syn.Kind (Of_Tree, From)
                                in Syn.Call | Syn.If_Statement
                                   | Syn.Match_Statement | Syn.Bare_Block
                           then
                              Lower_Stored_Expression
                                (Of_Tree, From, Scope, Destination.Slot);
                           else
                              declare
                                 Source : constant IR.Storage :=
                                   Storage_For (Of_Tree, From);
                              begin
                                 for Field in
                                   1 .. Landin.Checking.Signature_Result_Count
                                          (Types.all, Shape)
                                 loop
                                    Copy_Result_Field
                                      (Shape, Source, Destination, Field);
                                 end loop;
                              end;
                           end if;
                        end;

                     --  [0710]'s copy visits the same fields in [0750]'s
                     --  order: a scalar is one field read and write, and
                     --  D54 copies an array field with D50's compact
                     --  operation.  No whole-struct opcode says more.
                     elsif Landin.Checking.Type_Of
                          (Types.all, Of_Tree,
                           Syn.Target_Of (Of_Tree, Stmt)) = Ty.Aggregate
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           From : constant Syn.Node_Id :=
                             Syn.Value_Of (Of_Tree, Stmt);
                           Computed : constant Boolean :=
                             Has_Computed_Index (Of_Tree, Place);
                           Named : constant Syn.Node_Id :=
                             (if Computed then Syn.No_Node
                              else Chain_Root (Of_Tree, Place));
                           Parent_Field : constant Natural :=
                             (if Computed then 0
                              else Rooted_Base (Of_Tree, Place));
                           Parent_Steps : constant IR.Path_Step_Array :=
                             (if Computed then IR.No_Path_Steps
                              else Rooted_Steps (Of_Tree, Place));
                           Destination : constant IR.Storage :=
                             (if Computed
                              then (Kind => IR.Frame_Slot,
                                    Slot => IR.No_Slot)
                              else Storage_For (Of_Tree, Named));
                        begin
                           if Computed then
                              declare
                                 Reached : constant Stored_Place :=
                                   Lower_Stored_Place
                                     (Of_Tree, Place, Scope);
                                 Wrote : constant
                                   Landin.Checking.Nominal_Type_Id :=
                                   Landin.Checking.Nominal_Of
                                     (Types.all, Of_Tree, Place);
                              begin
                                 if Current /= IR.No_Block then
                                    declare
                                       Shape : constant IR.Field_Shape :=
                                         Neutral_Body (Wrote);
                                       Into : constant IR.Storage :=
                                         Addressed_Storage
                                           (Reached, Shape, Site);
                                    begin
                                       if Syn.Kind (Of_Tree, From)
                                            in Syn.Call | Syn.Try_Expression
                                               | Syn.If_Statement
                                               | Syn.Match_Statement
                                               | Syn.Bare_Block
                                               | Syn.Struct_Literal
                                               | Syn.Labeled_Application
                                               | Syn.Zeroed_Literal
                                       then
                                          declare
                                             Temporary : constant IR.Slot_Id :=
                                               Add_Value_Temporary
                                                 (Of_Tree, From);
                                             Temporary_Storage : constant
                                               IR.Storage :=
                                                 (Kind => IR.Frame_Slot,
                                                  Slot => Temporary);
                                          begin
                                             case Syn.Kind
                                               (Of_Tree, From)
                                             is
                                                when Syn.Call
                                                   | Syn.Try_Expression
                                                   | Syn.If_Statement
                                                   | Syn.Match_Statement
                                                   | Syn.Bare_Block =>
                                                   Lower_Stored_Expression
                                                     (Of_Tree, From, Scope,
                                                      Temporary);
                                                when Syn.Struct_Literal
                                                   | Syn.Labeled_Application =>
                                                   if Is_Struct_Construction
                                                     (Of_Tree, From)
                                                   then
                                                      Write_Struct_Literal
                                                        (From, Wrote,
                                                         Temporary_Storage);
                                                   else
                                                      raise
                                                        Landin.Compiler_Defect;
                                                   end if;
                                                when Syn.Zeroed_Literal =>
                                                   IR.Emit_Array_Clear
                                                     (Unit.all, Filling,
                                                      Temporary_Storage,
                                                      Site);
                                                when others =>
                                                   raise
                                                     Landin.Compiler_Defect;
                                             end case;
                                             if Current /= IR.No_Block then
                                                declare
                                                   Temp : Stored_Place :=
                                                     (Place =>
                                                        Temporary_Storage,
                                                      Base => 0,
                                                      Steps =>
                                                        Stored_Path_Vectors
                                                          .Empty_Vector);
                                                   From_Address : constant
                                                     IR.Storage :=
                                                       Addressed_Storage
                                                         (Temp, Shape, Site);
                                                begin
                                                   IR.Emit_Array_Copy
                                                     (Unit.all, Filling,
                                                      From_Address, Into,
                                                      Site);
                                                end;
                                             end if;
                                          end;
                                       else
                                          Copy_Aggregate_Value
                                            (Wrote, From, Into);
                                       end if;
                                    end;
                                 end if;
                              end;
                           elsif Syn.Kind (Of_Tree, From)
                                in Syn.If_Statement | Syn.Match_Statement
                                   | Syn.Bare_Block
                           then
                              declare
                                 Wrote : constant
                                   Landin.Checking.Nominal_Type_Id :=
                                   Landin.Checking.Nominal_Of
                                     (Types.all, Of_Tree, Place);
                                 Temporary : constant IR.Slot_Id :=
                                   IR.Add_Aggregate_Slot
                                     (Unit.all, Filling,
                                      Res.No_Declaration, Site,
                                      Nominal_For (Wrote));
                                 Source : constant IR.Storage :=
                                   (Kind => IR.Frame_Slot,
                                    Slot => Temporary);
                              begin
                                 for Field in
                                   1 .. Landin.Checking.Layout_Field_Count
                                          (Types.all, Wrote)
                                 loop
                                    Add_Stored_Field
                                      (Wrote, Field, Slot => Temporary);
                                 end loop;

                                 case Syn.Kind (Of_Tree, From) is
                                    when Syn.If_Statement =>
                                       Lower_If
                                         (Of_Tree, From, Scope, Result,
                                          Temporary);
                                    when Syn.Match_Statement =>
                                       Lower_Match
                                         (Of_Tree, From, Scope, Result,
                                          Temporary);
                                    when Syn.Bare_Block =>
                                       Lower_Bare_Block
                                         (Of_Tree, From, Scope, Result,
                                          Temporary);
                                    when others =>
                                       raise Landin.Compiler_Defect;
                                 end case;

                                 if Current /= IR.No_Block then
                                    for Field in
                                      1 .. Landin.Checking.Layout_Field_Count
                                             (Types.all, Wrote)
                                    loop
                                       Copy_Field
                                         (Wrote, Source, Destination, Field,
                                          Destination_Base => Parent_Field,
                                          Destination_Steps => Parent_Steps);
                                    end loop;
                                 end if;
                              end;
                           elsif Syn.Kind (Of_Tree, From)
                                   in Syn.Call | Syn.Try_Expression
                           then
                              pragma Assert
                                (Destination.Kind in IR.Frame_Slot);
                              if Syn.Kind (Of_Tree, From) = Syn.Call then
                                 declare
                                    Ignored : constant IR.Value_Id :=
                                      Lower_Call
                                        (Of_Tree, From, Scope,
                                         Destination => Destination.Slot,
                                         Destination_Field => Parent_Field,
                                         Destination_Steps => Parent_Steps);
                                 begin
                                    pragma Unreferenced (Ignored);
                                 end;
                              else
                                 declare
                                    Ignored : constant IR.Value_Id :=
                                      Lower_Call
                                        (Of_Tree,
                                         Syn.Operand_Of (Of_Tree, From),
                                         Scope,
                                         Destination => Destination.Slot,
                                         Destination_Field => Parent_Field,
                                         Destination_Steps => Parent_Steps,
                                         Propagate => True);
                                 begin
                                    pragma Unreferenced (Ignored);
                                 end;
                              end if;
                           elsif Is_Struct_Construction (Of_Tree, From) then
                              Write_Struct_Literal
                                (From,
                                 Landin.Checking.Nominal_Of
                                   (Types.all, Of_Tree, Place),
                                 Destination,
                                 Base  => Parent_Field,
                                 Steps => Parent_Steps);
                           elsif Syn.Kind (Of_Tree, From) = Syn.Zeroed_Literal
                           then
                              --  D58 clears a direct aggregate and D91 clears
                              --  one ordinary child. The field identity stays
                              --  neutral until the backend places it.
                              IR.Emit_Array_Clear
                                (Unit.all, Filling, Destination, Site,
                                 Field => Parent_Field,
                                 Nested => Parent_Steps);
                           else
                              Copy_Aggregate_Value
                                (Landin.Checking.Nominal_Of
                                   (Types.all, Of_Tree, Place),
                                 From, Destination,
                                 Destination_Base => Parent_Field,
                                 Destination_Steps => Parent_Steps);
                           end if;
                        end;
                     elsif Landin.Checking.Type_Of
                             (Types.all, Of_Tree,
                              Syn.Target_Of (Of_Tree, Stmt)) = Ty.Fixed_Array
                     then
                        declare
                           Value : constant Syn.Node_Id :=
                             Syn.Value_Of (Of_Tree, Stmt);
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Named : constant Syn.Node_Id :=
                             Chain_Root (Of_Tree, Place);
                           Field : constant Natural :=
                             Rooted_Base (Of_Tree, Place);
                           Child_Steps : constant IR.Path_Step_Array :=
                             Rooted_Steps (Of_Tree, Place);
                           Destination : constant IR.Storage :=
                             Storage_For (Of_Tree, Named);
                        begin
                           if Syn.Kind (Of_Tree, Value)
                                in Syn.If_Statement | Syn.Match_Statement
                                   | Syn.Bare_Block
                           then
                              declare
                                 Temporary : constant IR.Slot_Id :=
                                   Add_Value_Temporary (Of_Tree, Value);
                              begin
                                 Lower_Stored_Expression
                                   (Of_Tree, Value, Scope, Temporary);

                                 if Current /= IR.No_Block then
                                    IR.Emit_Array_Copy
                                      (Unit.all, Filling,
                                       Source =>
                                         (Kind => IR.Frame_Slot,
                                          Slot => Temporary),
                                       Destination => Destination,
                                       Site => Site,
                                       Destination_Field => Field,
                                       Destination_Nested => Child_Steps);
                                 end if;
                              end;
                           elsif Syn.Kind (Of_Tree, Value)
                                   in Syn.Call | Syn.Try_Expression
                           then
                              pragma Assert
                                (Destination.Kind in IR.Frame_Slot);
                              declare
                                 Actual_Call : constant Syn.Node_Id :=
                                   (if Syn.Kind (Of_Tree, Value) = Syn.Call
                                    then Value
                                    else Syn.Operand_Of (Of_Tree, Value));
                                 Ignored : constant IR.Value_Id :=
                                   Lower_Call
                                     (Of_Tree, Actual_Call, Scope,
                                      Destination => Destination.Slot,
                                      Destination_Field => Field,
                                      Destination_Steps => Child_Steps,
                                      Propagate =>
                                        Syn.Kind (Of_Tree, Value)
                                          = Syn.Try_Expression);
                              begin
                                 pragma Unreferenced (Ignored);
                              end;
                           else
                              --  D49--D53/D65 and D90 share one
                              --  field-qualified lowering rule for each
                              --  contextual array value.
                              Write_Array_Value
                                (Value, Destination, Field,
                                 Path => Child_Steps);
                           end if;
                        end;
                     else
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Index : constant IR.Value_Id := Index_For (Place);
                           Saved_Index : IR.Slot_Id := IR.No_Slot;
                        begin
                           --  The right-hand side can cross blocks through a
                           --  short circuit.  Save the already-evaluated
                           --  destination index before it runs, then reload it
                           --  in the block where the store is emitted.
                           if Current /= IR.No_Block
                             and then Index /= IR.No_Value
                           then
                              Saved_Index :=
                                IR.Add_Slot
                                  (Unit.all, Filling, Ty.Usize,
                                   Res.No_Declaration, Site);
                              IR.Emit_Store
                                (Unit.all, Filling, Saved_Index, Index, Site);
                           end if;

                           if Current /= IR.No_Block then
                              declare
                                 Value : constant IR.Value_Id :=
                                   Lower_Expression
                                     (Of_Tree,
                                      Syn.Value_Of (Of_Tree, Stmt), Scope);
                              begin
                                 if Current /= IR.No_Block then
                                    declare
                                       Carried_Index : constant IR.Value_Id :=
                                         (if Saved_Index = IR.No_Slot
                                          then IR.No_Value
                                          else IR.Emit_Load
                                                 (Unit.all, Filling,
                                                  Saved_Index, Site));
                                    begin
                                       Write (Place, Value, Carried_Index);
                                    end;
                                 end if;
                              end;
                           end if;
                        end;
                     end if;

                  when Syn.Increment | Syn.Decrement =>
                     --  [1900]: `inc` says what `x += 1` says, which is a
                     --  load, a one, a trapping add and a store.
                     declare
                        Place : constant Syn.Node_Id :=
                          Syn.Target_Of (Of_Tree, Stmt);
                        Held : constant Ty.Scalar_Name :=
                          Scalar_At (Of_Tree, Place);
                        Index : constant IR.Value_Id := Index_For (Place);
                        Op : constant IR.Opcode :=
                          (if Syn.Kind (Of_Tree, Stmt) = Syn.Increment
                           then IR.Add else IR.Subtract);
                     begin
                        if Current /= IR.No_Block then
                           declare
                              Was : constant IR.Value_Id :=
                                Read_Place (Place, Index);
                              One : constant IR.Value_Id :=
                                IR.Emit_Number
                                  (Unit.all, Filling, Held, 1, False, Site);
                           begin
                              Write
                                (Place,
                                 IR.Emit_Binary
                                   (Unit.all, Filling, Op, Was, One, Held,
                                    Site),
                                 Index);
                           end;
                        end if;
                     end;

                  when Syn.Discard =>
                     --  [1930]: the value is thrown away, which is an
                     --  unused scalar value and needs no opcode to say so.
                     --  D112 still gives a returned aggregate temporary
                     --  lifetime through the call before discarding it.
                     declare
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Stmt);
                     begin
                        if Type_At (Of_Tree, Value)
                             in Ty.Aggregate | Ty.Fixed_Array
                        then
                           declare
                              Temporary : constant IR.Slot_Id :=
                                Add_Value_Temporary (Of_Tree, Value);
                           begin
                              Lower_Stored_Expression
                                (Of_Tree, Value, Scope, Temporary);
                           end;
                        else
                           declare
                              Ignored : constant IR.Value_Id :=
                                Lower_Expression (Of_Tree, Value, Scope);
                           begin
                              pragma Assert
                                (Ignored /= IR.No_Value
                                 or else Current = IR.No_Block);
                           end;
                        end if;
                     end;

                  when Syn.Try_Expression =>
                     declare
                        Ignored : constant IR.Value_Id :=
                          Lower_Call
                            (Of_Tree, Syn.Operand_Of (Of_Tree, Stmt), Scope,
                             Propagate => True);
                     begin
                        pragma Assert
                          (Ignored /= IR.No_Value
                           or else Current = IR.No_Block);
                     end;

                  when Syn.Call =>
                     declare
                        Ignored : constant IR.Value_Id :=
                          Lower_Call (Of_Tree, Stmt, Scope);
                     begin
                        pragma Assert
                          (Ignored /= IR.No_Value
                           or else Current = IR.No_Block);
                     end;

                  when Syn.Defer_Statement | Syn.Undo_Statement =>
                     --  Registration emits nothing and evaluates nothing.
                     --  The call syntax and its lexical scope are retained
                     --  until an applicable edge leaves this block.
                     Cleanup_Stack.Append
                       (Cleanup_Entry'
                          (Kind   =>
                             (if Syn.Kind (Of_Tree, Stmt)
                                   = Syn.Undo_Statement
                              then Cleanup.Failure_Undo
                              else Cleanup.Deferred_Call),
                           Call   => Syn.Cleanup_Call (Of_Tree, Stmt),
                           Scope  => Scope,
                           Active => True));

                  when Syn.Fail_Statement =>
                     if Syn.Condition_Of (Of_Tree, Stmt) = Syn.No_Node
                     then
                        declare
                           Error : constant IR.Value_Id :=
                             Lower_Expression
                               (Of_Tree, Syn.Value_Of (Of_Tree, Stmt), Scope);
                        begin
                           if Current /= IR.No_Block then
                              Fail_Through_Cleanups (Of_Tree, Error, Site);
                           end if;
                        end;
                     else
                        declare
                           Test : constant IR.Value_Id :=
                             Lower_Expression
                               (Of_Tree,
                                Syn.Condition_Of (Of_Tree, Stmt), Scope);
                        begin
                           if Current /= IR.No_Block then
                              declare
                                 Goes : constant IR.Block_Id :=
                                   Fresh (Of_Tree, Stmt, Scope);
                                 Stays : constant IR.Block_Id :=
                                   Fresh (Of_Tree, Stmt, Scope);
                              begin
                                 IR.Emit_Branch
                                   (Unit.all, Filling, Test, Goes, Stays,
                                    Site);
                                 IR.Leave_Block (Unit.all, Filling);
                                 Current := IR.No_Block;

                                 Open (Goes);
                                 declare
                                    Error : constant IR.Value_Id :=
                                      Lower_Expression
                                        (Of_Tree,
                                         Syn.Value_Of (Of_Tree, Stmt),
                                         Scope);
                                 begin
                                    if Current /= IR.No_Block then
                                       Fail_Through_Cleanups
                                         (Of_Tree, Error, Site);
                                    end if;
                                 end;

                                 Open (Stays);
                              end;
                           end if;
                        end;
                     end if;

                  when Syn.Return_Statement =>
                     if Syn.Condition_Of (Of_Tree, Stmt) = Syn.No_Node
                     then
                        Leave_Through_Cleanups
                          (Of_Tree, Result, Site);
                     else
                        --  [1810]: only an exit carries `when`, so the
                        --  flow below it is reachable and the guard is a
                        --  branch into a block that leaves.
                        declare
                           Test : constant IR.Value_Id :=
                             Lower_Expression
                               (Of_Tree,
                                Syn.Condition_Of (Of_Tree, Stmt), Scope);
                        begin
                           if Current /= IR.No_Block then
                              declare
                                 Goes : constant IR.Block_Id :=
                                   Fresh (Of_Tree, Stmt, Scope);
                                 Stays : constant IR.Block_Id :=
                                   Fresh (Of_Tree, Stmt, Scope);
                              begin
                                 IR.Emit_Branch
                                   (Unit.all, Filling, Test, Goes, Stays,
                                    Site);
                                 IR.Leave_Block (Unit.all, Filling);
                                 Current := IR.No_Block;

                                 Open (Goes);
                                 Leave_Through_Cleanups
                                   (Of_Tree, Result, Site);

                                 Open (Stays);
                              end;
                           end if;
                        end;
                     end if;

                  when Syn.If_Statement =>
                     Lower_If (Of_Tree, Stmt, Scope, Result);

                  when Syn.Match_Statement =>
                     Lower_Match (Of_Tree, Stmt, Scope, Result);

                  when Syn.Bare_Block =>
                     Lower_Bare_Block (Of_Tree, Stmt, Scope, Result);

                  when others =>
                     raise Landin.Compiler_Defect with
                       "a statement the lowering does not know";
                  end case;
               end if;
            end;
         end loop;

         if Current /= IR.No_Block then
            --  A block's final expression has already filled its consumer's
            --  join storage.  Now leave this lexical frame in reverse
            --  registration order before a surrounding control merge.
            Emit_Cleanups
              (Of_Tree, Cleanup_Base + 1,
               Cleanup.Normal_Fallthrough);
         end if;

         while Natural (Cleanup_Stack.Length) > Cleanup_Base loop
            Cleanup_Stack.Delete_Last;
         end loop;
      end Lower_Statements;

      ------------------------------------------------------------
      --  [1800]: a function
      ------------------------------------------------------------

      procedure Lower_Routine (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Lower_Routine (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Src : constant Landin.Source.Source_Id := Syn.Source_Of (Of_Tree);
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Signature : constant Res.Scope_Id :=
           Res.Scope_At (Meanings.all, Of_Tree, Node);
         Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Node);
         Return_Count : constant Natural :=
           Syn.Return_Count (Of_Tree, Node);
         Gives : constant Syn.Node_Id :=
           (if Return_Count = 1
            then Syn.Nth_Return (Of_Tree, Node, 1) else Syn.No_Node);
         Gives_Type : constant Ty.Type_Kind :=
           (if Return_Count = 0 then Ty.No_Value
            elsif Return_Count > 1 then Ty.Aggregate
            else Landin.Checking.Type_Of
              (Types.all, Declaration_At (Src, Gives)));
         Source_Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Signature_Of (Types.all, Of_Tree, Node);
         Result : IR.Slot_Id := IR.No_Slot;
         Owner : constant Res.Declaration_Id :=
           (if Syn.Kind (Of_Tree, Node) = Syn.Function_Declaration
            then Declaration_At (Src, Node) else Res.No_Declaration);
      begin
         Filling :=
           (if Landin.Checking.Current_Routine_View (Types.all)
                  /= Landin.Checking.No_Routine_Instance
            then IR.Item_For_Instance
              (Unit.all,
               Landin.Checking.Routine_Identities.Position
                 (Types.all,
                  Landin.Checking.Current_Routine_View (Types.all)))
            elsif Owner = Res.No_Declaration
            then Anonymous_Item (Of_Tree, Node)
            else IR.Item_For (Unit.all, Owner));
         Slots := No_Slots;
         pragma Assert (Cleanup_Stack.Is_Empty);
         Cleanup_Stack.Clear;

         --  D106's first internal parameter is an unspellable pointer to
         --  caller-owned result storage.  Source parameters follow it through
         --  the same register/stack run.
         if Gives_Type in Ty.Aggregate | Ty.Fixed_Array then
            declare
               Ignored : constant IR.Slot_Id :=
                 IR.Add_Parameter
                   (Unit.all, Filling, Ty.Usize, Owner, Site);
            begin
               pragma Unreferenced (Ignored);
            end;
         end if;

         --  [1920] names the parameters in order, so the run is that
         --  order and the ABI has somewhere to put an argument.
         for Which in 1 .. Syn.Parameter_Count (Of_Tree, Node) loop
            declare
               Param : constant Syn.Node_Id :=
                 Syn.Nth_Parameter (Of_Tree, Node, Which);
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Src, Param);
               Held : constant Ty.Type_Kind :=
                 Landin.Checking.Type_Of (Types.all, Id);
            begin
               if Held = Ty.Aggregate then
                  declare
                     Nominal : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of (Types.all, Id);
                  begin
                     Slots (Positive (Id)) :=
                       IR.Add_Aggregate_Parameter
                         (Unit.all, Filling, Id, Site_Of (Of_Tree, Param),
                          Nominal_For (Nominal));
                     for Field in
                       1 .. Landin.Checking.Layout_Field_Count
                         (Types.all, Nominal)
                     loop
                        Add_Stored_Field
                          (Nominal, Field, Slot => Slots (Positive (Id)));
                     end loop;
                  end;
               elsif Held = Ty.Fixed_Array then
                  Slots (Positive (Id)) :=
                    IR.Add_Array_Parameter
                      (Unit.all, Filling,
                       Neutral_Element (Id),
                       IR.Element_Total
                         (Landin.Checking.Array_Length (Types.all, Id)),
                       Id, Site_Of (Of_Tree, Param));
               elsif Held in
                 Ty.Scalar_Name | Ty.Function_Value | Ty.Atom_Value
               then
                  Slots (Positive (Id)) :=
                    IR.Add_Parameter
                      (Unit.all, Filling,
                       (if Held = Ty.Function_Value then Ty.Usize
                        elsif Held = Ty.Atom_Value then Ty.U32
                        else Held),
                       Id, Site_Of (Of_Tree, Param),
                       Signature =>
                         (if Held = Ty.Function_Value
                          then Signature_For
                            (Landin.Checking.Signature_Of (Types.all, Id))
                          else IR.No_Signature),
                       Atoms =>
                         (if Held = Ty.Atom_Value
                          then Atom_Set_For
                            (Landin.Checking.Atom_Set_Of (Types.all, Id))
                          else IR.No_Atom_Set));
               else
                  raise Landin.Compiler_Defect with
                    "a parameter reached the lowering with no storable type";
               end if;
            end;
         end loop;

         if Return_Count = 1 then
            declare
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Src, Gives);
            begin
               Result := Slot_For (Of_Tree, Gives, Id);
               IR.Set_Result_Slot (Unit.all, Filling, Result);
            end;
         elsif Return_Count > 1 then
            Result := IR.Add_Aggregate_Slot
              (Unit.all, Filling, Res.No_Declaration, Site);
            Add_Result_Fields (Source_Signature, Slot => Result);
            IR.Set_Result_Slot (Unit.all, Filling, Result);

            --  Each source-level named return is an independently tracked
            --  place, but all write their own field of the one caller-owned
            --  structural result slot.  No final packing copy is needed.
            for Which in 1 .. Return_Count loop
               declare
                  Returned : constant Syn.Node_Id :=
                    Syn.Nth_Return (Of_Tree, Node, Which);
                  Id : constant Res.Declaration_Id :=
                    Declaration_At (Src, Returned);
               begin
                  Aliases (Declared (Id)) :=
                    (Active        => True,
                     Source        => (Kind => IR.Frame_Slot, Slot => Result),
                     Field         => Which,
                     Subject       => Syn.No_Node,
                     Which         => 0,
                     Payload_Field => 0);
               end;
            end loop;
         end if;

         Active_Result := Result;

         if Syn.Kind (Of_Tree, Runs) = Syn.Block then
            declare
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
            begin
               Open (Fresh (Of_Tree, Runs, Inside));
               Lower_Statements (Of_Tree, Runs, Inside, Result);

               --  [0930]: the named return is assigned by every path that
               --  reaches the end, so falling off it leaves with the
               --  value that is in it.
               if Current /= IR.No_Block then
                  Leave_With (Result, Site);
               end if;
            end;
         else
            --  [0880]: the expression fills the named return, and [1840]
            --  says it opens no scope, so its block is the signature's.
            Open (Fresh (Of_Tree, Runs, Signature));

            if Gives_Type in Ty.Aggregate | Ty.Fixed_Array then
               Lower_Stored_Expression
                 (Of_Tree, Runs, Signature, Result);
            else
               declare
                  Value : constant IR.Value_Id :=
                    Lower_Expression (Of_Tree, Runs, Signature);
               begin
                  if Result /= IR.No_Slot then
                     IR.Emit_Store
                       (Unit.all, Filling, Result, Value, Site);
                  end if;
               end;
            end if;

            Leave_With (Result, Site);
         end if;

         Filling := IR.No_Item;
         Active_Result := IR.No_Slot;
         pragma Assert (Cleanup_Stack.Is_Empty);
      end Lower_Routine;

      ------------------------------------------------------------
      --  [1940]: a module value
      ------------------------------------------------------------

      function Static_Function_Target
        (Id : Res.Declaration_Id) return IR.Item_Id;

      function Static_Function_Target
        (Id : Res.Declaration_Id) return IR.Item_Id
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree.all, Node);
      begin
         if Static_Function_Targets (Positive (Id)) /= IR.No_Item then
            return Static_Function_Targets (Positive (Id));
         end if;
         if Finding_Static_Function (Positive (Id)) then
            raise Landin.Compiler_Defect with
              "a static function image cycle reached lowering";
         end if;
         Finding_Static_Function (Positive (Id)) := True;

         if Value /= Syn.No_Node
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Anonymous_Function
         then
            Static_Function_Targets (Positive (Id)) :=
              Anonymous_Item (Of_Tree.all, Value);
         elsif Value /= Syn.No_Node
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree.all, Value)
                      = Res.Bound
         then
            declare
               Source_Id : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree.all, Value);
            begin
               if Res.Sort_Of (Meanings.all, Source_Id)
                    = Res.Module_Function
               then
                  Static_Function_Targets (Positive (Id)) :=
                    IR.Item_For (Unit.all, Source_Id);
               elsif Res.Sort_Of (Meanings.all, Source_Id)
                       = Res.Module_Binding
               then
                  Static_Function_Targets (Positive (Id)) :=
                    Static_Function_Target (Source_Id);
               end if;
            end;
         end if;

         Finding_Static_Function (Positive (Id)) := False;
         if Static_Function_Targets (Positive (Id)) = IR.No_Item then
            raise Landin.Compiler_Defect with
              "a module function value has no static routine target";
         end if;
         return Static_Function_Targets (Positive (Id));
      end Static_Function_Target;

      --  A datum's block describes its value.  [1460] says nothing runs
      --  before the entry point, so this is not code and R1.80 reads it
      --  rather than executing it.
      procedure Lower_Datum (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Lower_Datum (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Src : constant Landin.Source.Source_Id := Syn.Source_Of (Of_Tree);
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Id : constant Res.Declaration_Id := Declaration_At (Src, Node);
         Held : constant Ty.Type_Kind :=
           Landin.Checking.Type_Of (Types.all, Id);
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
         Answer : IR.Value_Id;
      begin
         if Held not in Ty.Scalar_Name | Ty.Function_Value | Ty.Atom_Value
           and then Held not in Ty.Aggregate | Ty.Fixed_Array
         then
            raise Landin.Compiler_Defect with
              "a module binding reached the lowering with no storable type";
         end if;

         Filling := IR.Item_For (Unit.all, Id);
         Slots := No_Slots;

         --  Aggregate state has no runtime-producing value.  D10 zeroes a
         --  struct, while R2.20 has proved that every direct-name module array
         --  image chain terminates at a D10-zeroed array.  Each declaration
         --  still owns a distinct datum whose storage is described by the
         --  fields or shape the item was given, so its block carries no value.
         if Held in Ty.Aggregate | Ty.Fixed_Array then
            Open (Fresh (Of_Tree, Node, Res.Program_Scope));
            IR.Emit_Leave (Unit.all, Filling, IR.No_Value, Site);
            IR.Leave_Block (Unit.all, Filling);
            Current := IR.No_Block;
            Filling := IR.No_Item;
            return;
         end if;

         --  [1840]: a module value is read in the module scope, and
         --  [1800]'s expression body is the only other thing that opens
         --  none.  So the block carries the scope the resolver read it in.
         Open (Fresh (Of_Tree, Node, Res.Program_Scope));

         if Held = Ty.Function_Value then
            declare
               Target : constant IR.Item_Id := Static_Function_Target (Id);
            begin
               IR.Set_Function_Target (Unit.all, Filling, Target);
               Answer :=
                 IR.Emit_Function_Address (Unit.all, Filling, Target, Site);
            end;
         elsif Value = Syn.No_Node
           or else Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
         then
            --  D10: a binding with no value holds zero, false for a bool.
            --  D39's contextual scalar `zeroed` is exactly that existing
            --  scalar IR, not a separately evaluated expression.
            if Held = Ty.Bool then
               Answer :=
                 IR.Emit_Truth (Unit.all, Filling, False, Site);
            else
               Answer :=
                 IR.Emit_Number
                   (Unit.all, Filling, Held, 0, False, Site);
            end if;
         else
            Answer := Lower_Expression (Of_Tree, Value, Res.Program_Scope);
         end if;

         IR.Emit_Leave (Unit.all, Filling, Answer, Site);
         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;
         Filling := IR.No_Item;
      end Lower_Datum;


   begin
      --  Nothing that was refused is lowered, and this stage says so
      --  itself rather than trusting the order it was queued in.  R1.70
      --  assigns no diagnostic code because malformed IR cannot come from
      --  a source program, and that is only true while this holds.
      if Failed (Context) then
         Outcome := Stop;
         return;
      end if;

      IR.Prepare (Unit.all, Meanings.all);

      --  Map every checker identity in checker order before recursively
      --  lowering any shape.  First-use order therefore cannot renumber IR.
      for Position in 1 .. Landin.Checking.Nominal_Type_Count (Types.all) loop
         declare
            Source : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nth_Nominal_Type (Types.all, Position);
            Template : constant Res.Declaration_Id :=
              Landin.Checking.Template_Of (Types.all, Source);
         begin
            Nominals (Position) := IR.Add_Nominal_Type (Unit.all, Template);
         end;
      end loop;

      --  Pass one: every active item, over every tree, before any is
      --  filled.  D139's shared declaration traversal flattens selected
      --  runs before this action sees them.
      declare
         procedure Add_Declaration
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

         procedure Add_Declaration
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
         is
            Src : constant Landin.Source.Source_Id := Syn.Source_Of (Of_Tree);
            Id : constant Res.Declaration_Id := Declaration_At (Src, Node);
            Made : IR.Item_Id;
         begin
            case Syn.Kind (Of_Tree, Node) is
            when Syn.Function_Declaration =>
               declare
                  Count : constant Natural :=
                    Syn.Return_Count (Of_Tree, Node);
                  Gives : constant Syn.Node_Id :=
                    (if Count = 1
                     then Syn.Nth_Return (Of_Tree, Node, 1)
                     else Syn.No_Node);
                  Held : constant Ty.Type_Kind :=
                    (if Count = 0 then Ty.No_Value
                     elsif Count > 1 then Ty.Aggregate
                     else Landin.Checking.Type_Of
                            (Types.all,
                             Declaration_At (Src, Gives)));
               begin
                  if Syn.Generic_Formal_Count (Of_Tree, Node) /= 0 then
                     --  D138 templates are compile-time syntax only; a
                     --  concrete instance owns the local routine item.
                     Made := IR.No_Item;
                  else
                     Made :=
                       IR.Add_Item
                         (Unit.all, IR.Routine, Id,
                          (if Held = Ty.Function_Value
                           then Ty.Usize
                           elsif Held = Ty.Atom_Value then Ty.U32 else Held),
                          Site_Of (Of_Tree, Node),
                          Nominal =>
                            (if Held = Ty.Aggregate and then Count = 1
                             then Nominal_For
                               (Landin.Checking.Nominal_Of
                                  (Types.all,
                                   Declaration_At (Src, Gives)))
                             else IR.No_Nominal_Type));
                     if Held = Ty.Atom_Value then
                        IR.Set_Atom_Set
                          (Unit.all, Made,
                           Atom_Set_For
                             (Landin.Checking.Atom_Set_Of
                                (Types.all,
                                 Declaration_At (Src, Gives))));
                     end if;
                     IR.Set_Signature
                       (Unit.all, Made,
                        Signature_For
                          (Landin.Checking.Signature_Of
                             (Types.all, Id)));
                  end if;
               end;

            when Syn.Binding =>
               declare
                  Held : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Id);
               begin
                  Made :=
                    IR.Add_Item
                      (Unit.all, IR.Datum, Id,
                       (if Held = Ty.Function_Value
                        then Ty.Usize
                        elsif Held = Ty.Atom_Value
                        then Ty.U32 else Held),
                       Site_Of (Of_Tree, Node),
                       Nominal =>
                         (if Held = Ty.Aggregate
                          then Nominal_For
                            (Landin.Checking.Nominal_Of
                               (Types.all, Id))
                          else IR.No_Nominal_Type));

                  if Held = Ty.Atom_Value then
                     IR.Set_Atom_Set
                       (Unit.all, Made,
                        Atom_Set_For
                          (Landin.Checking.Atom_Set_Of
                             (Types.all, Id)));
                  end if;

                  if Held = Ty.Function_Value then
                     IR.Set_Signature
                       (Unit.all, Made,
                        Signature_For
                          (Landin.Checking.Signature_Of
                             (Types.all, Id)));
                  end if;

                  --  [0520]'s shape: one element and a count,
                  --  because an array is its element repeated
                  --  and a run of them would be as long as the
                  --  count, which reaches four billion.
                  if Held = Ty.Fixed_Array then
                     IR.Set_Array
                       (Unit.all, Made,
                        Neutral_Element (Id),
                        IR.Element_Total
                          (Landin.Checking.Array_Length
                             (Types.all, Id)));
                  end if;

                  --  [0750]'s fields, in the order they were
                  --  written.  The compact scalar or fixed-array
                  --  shapes and not the offsets: a backend has a
                  --  description and works out the same placement
                  --  the checker did.
                  if Held = Ty.Aggregate then
                     declare
                        Nominal : constant
                          Landin.Checking.Nominal_Type_Id :=
                            Landin.Checking.Nominal_Of
                              (Types.all, Id);
                     begin
                        for Field in
                          1 .. Landin.Checking.Layout_Field_Count
                            (Types.all, Nominal)
                        loop
                           Add_Stored_Field
                             (Nominal, Field, Datum => Made);
                        end loop;
                     end;
                  end if;
               end;

            when others =>
               Made := IR.No_Item;
            end case;

            pragma Assert (Made /= IR.No_Item or else True);
         end Add_Declaration;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Nth_Source (Context, Index));
               procedure Walk is new
                 Landin.Configuration.For_Each_Active_Declaration
                   (Add_Declaration);
            begin
               Walk (Activity.all, Of_Tree.all);
            end;
         end loop;
      end;

      --  Ready generic routine instances follow declaration-backed items in
      --  checker interning order.  Their source template remains provenance;
      --  the item itself is local and keyed by the opaque instance position.
      for Position in 1 .. Landin.Checking.Routine_Instance_Count (Types.all)
      loop
         declare
            Source : constant Landin.Checking.Routine_Instance_Id :=
              Landin.Checking.Routine_Identities.Nth (Types.all, Position);
         begin
            if Landin.Checking.Routine_State_Of (Types.all, Source)
              = Landin.Checking.Routine_Ready
            then
               declare
                  Template : constant Res.Declaration_Id :=
                    Landin.Checking.Routine_Template_Of (Types.all, Source);
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Template));
                  Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Template);
                  Source_Signature : constant Landin.Checking.Signature_Id :=
                    Landin.Checking.Routine_Signature_Of
                      (Types.all, Source);
                  Result_Count : constant Natural :=
                    Landin.Checking.Signature_Result_Count
                      (Types.all, Source_Signature);
                  Part : constant Landin.Checking.Signature_Part :=
                    (if Result_Count = 1
                     then Landin.Checking.Nth_Signature_Result
                       (Types.all, Source_Signature, 1)
                     else (Kind => Ty.No_Value, others => <>));
                  Held : constant Ty.Type_Kind :=
                    (if Result_Count = 0 then Ty.No_Value
                     elsif Result_Count > 1 then Ty.Aggregate
                     else Part.Kind);
                  Made : constant IR.Item_Id :=
                    IR.Add_Routine_Instance_Item
                      (Unit.all, Position, Template,
                       (if Held = Ty.Function_Value then Ty.Usize
                        elsif Held = Ty.Atom_Value then Ty.U32 else Held),
                       Site_Of (Of_Tree.all, Node),
                       Nominal =>
                         (if Held = Ty.Aggregate and then Result_Count = 1
                          then Nominal_For (Part.Nominal)
                          else IR.No_Nominal_Type));
               begin
                  if Held = Ty.Atom_Value then
                     IR.Set_Atom_Set
                       (Unit.all, Made, Atom_Set_For (Part.Atoms));
                  end if;
                  IR.Set_Signature
                    (Unit.all, Made, Signature_For (Source_Signature));
               end;
            end if;
         end;
      end loop;

      --  Anonymous routines follow every declaration item, in source order
      --  and then syntax post-order.  That order is independent of traversal
      --  recursion and gives each no-capture function one deterministic item
      --  before any address can name it.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
            Src : constant Landin.Source.Source_Id :=
              Syn.Source_Of (Of_Tree.all);
         begin
            for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Of_Tree.all) loop
               if Syn.Kind (Of_Tree.all, Node) = Syn.Anonymous_Function
                 and then Landin.Configuration.Is_Active
                   (Activity.all, Syn.Source_Of (Of_Tree.all), Node)
               then
                  declare
                     Count : constant Natural :=
                       Syn.Return_Count (Of_Tree.all, Node);
                     Gives : constant Syn.Node_Id :=
                       (if Count = 1
                        then Syn.Nth_Return (Of_Tree.all, Node, 1)
                        else Syn.No_Node);
                     Held : constant Ty.Type_Kind :=
                       (if Count = 0 then Ty.No_Value
                        elsif Count > 1 then Ty.Aggregate
                        else Landin.Checking.Type_Of
                          (Types.all, Declaration_At (Src, Gives)));
                     Made : constant IR.Item_Id :=
                       IR.Add_Item
                         (Unit.all, IR.Routine, Res.No_Declaration,
                          (if Held = Ty.Function_Value
                           then Ty.Usize
                           elsif Held = Ty.Atom_Value
                           then Ty.U32 else Held),
                          Site_Of (Of_Tree.all, Node),
                          Nominal =>
                            (if Held = Ty.Aggregate and then Count = 1
                             then Nominal_For
                               (Landin.Checking.Nominal_Of
                                  (Types.all, Declaration_At (Src, Gives)))
                             else IR.No_Nominal_Type));
                  begin
                     if Held = Ty.Atom_Value then
                        IR.Set_Atom_Set
                          (Unit.all, Made,
                           Atom_Set_For
                             (Landin.Checking.Atom_Set_Of
                                (Types.all, Declaration_At (Src, Gives))));
                     end if;
                     IR.Set_Signature
                       (Unit.all, Made,
                        Signature_For
                          (Landin.Checking.Signature_Of
                             (Types.all, Of_Tree.all, Node)));
                     Anonymous_Count := Anonymous_Count + 1;
                     Anonymous_Routines (Anonymous_Count) :=
                       (Source => Src, Node => Node, Item => Made);
                  end;
               end if;
            end loop;
         end;
      end loop;

      --  Pass two: fill every active item in the same declaration order.
      declare
         procedure Lower_Declaration
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

         procedure Lower_Declaration
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
         begin
            case Syn.Kind (Of_Tree, Node) is
               when Syn.Function_Declaration =>
                  if Syn.Generic_Formal_Count (Of_Tree, Node) = 0 then
                     Lower_Routine (Of_Tree, Node);
                  end if;
               when Syn.Binding =>
                  Lower_Datum (Of_Tree, Node);
               when others =>
                  null;
            end case;
         end Lower_Declaration;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Nth_Source (Context, Index));
               procedure Walk is new
                 Landin.Configuration.For_Each_Active_Declaration
                   (Lower_Declaration);
            begin
               Walk (Activity.all, Of_Tree.all);
            end;
         end loop;
      end;

      for Position in 1 .. Landin.Checking.Routine_Instance_Count (Types.all)
      loop
         declare
            Source : constant Landin.Checking.Routine_Instance_Id :=
              Landin.Checking.Routine_Identities.Nth (Types.all, Position);
         begin
            if Landin.Checking.Routine_State_Of (Types.all, Source)
              = Landin.Checking.Routine_Ready
            then
               declare
                  Template : constant Res.Declaration_Id :=
                    Landin.Checking.Routine_Template_Of (Types.all, Source);
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Template));
                  Previous : Landin.Checking.Routine_Instance_Id;
               begin
                  Landin.Checking.Activate_Routine_View
                    (Types.all, Source, Previous);
                  Lower_Routine
                    (Of_Tree.all, Res.Node_Of (Meanings.all, Template));
                  Landin.Checking.Restore_Routine_View
                    (Types.all, Previous);
               exception
                  when others =>
                     Landin.Checking.Restore_Routine_View
                       (Types.all, Previous);
                     raise;
               end;
            end if;
         end;
      end loop;

      for Index in 1 .. Anonymous_Count loop
         declare
            Routine_Entry : Anonymous_Entry renames
              Anonymous_Routines (Index);
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Routine_Entry.Source);
         begin
            Lower_Routine (Of_Tree.all, Routine_Entry.Node);
         end;
      end loop;

      --  Pass three: D24/D34/D66 initial-image resolution.  Array datums keep
      --  their per-position or compact repetition folds; an aggregate literal
      --  carries one fold per declaration-order field.  A direct storage name
      --  follows D21/D60/D61's chain while preserving the source image.  An
      --  absent or explicit zero image stays reserved in `.bss`; a written
      --  image reaches `.data`.  This pass follows Lower_Datum because a
      --  source may be written below its use [1740].
      Resolve_Module_Images :
      declare
         Declarations : constant Natural :=
           Res.Declaration_Count (Meanings.all);
         subtype Numbered is
           Res.Declaration_Id range 1 .. Res.Declaration_Id
                                          (Positive'Max (1, Declarations));

         type Image_State is (Unseen, Visiting, Resolved);

         Where : array (Numbered) of Image_State := [others => Unseen];
         Made  : array (Numbered) of Boolean := [others => False];

         package Descriptor_Vectors is new Ada.Containers.Vectors
           (Index_Type   => Positive,
            Element_Type => IR.Aggregate_Field_Image,
            "="          => IR."=");
         package Fold_Vectors is new Ada.Containers.Vectors
           (Index_Type   => Positive,
            Element_Type => Ty.Folded,
            "="          => Ty."=");

         --  Every [1820] operator [1940] admits over literals, so a
         --  bool comparison, a bitwise expression, a shift or a wrapping
         --  arithmetic operator produces the same image bytes here that
         --  the backend's own module-value fold would have produced for
         --  a scalar module binding: one target-aware folder for both.
         --  Constructs the checker excludes from D24 (a call, a member
         --  selection, an element index and a nested array literal) are
         --  refused before this pass reads them and reach here as a
         --  compiler defect, not as [1940] silently narrowed.
         type Pattern is mod 2 ** 64;
         function Mask
           (Value : Pattern;
            Bits  : Landin.Targets.Bit_Width) return Pattern
           is (if Bits >= 64 then Value
               else Value and (2 ** Natural (Bits) - 1));
         function Is_Negative
           (Value : Pattern;
            Bits  : Landin.Targets.Bit_Width) return Boolean
           is ((Value and 2 ** (Natural (Bits) - 1)) /= 0);
         function To_Pattern
           (Value : Ty.Folded;
            Bits  : Landin.Targets.Bit_Width) return Pattern
           is (if Value < 0
               then Mask (0 - Pattern (-Value), Bits)
               else Mask (Pattern (Value), Bits));
         function As_Number
           (Value  : Pattern;
            Bits   : Landin.Targets.Bit_Width;
            Signed : Boolean) return Ty.Folded
           is (if Signed and then Is_Negative (Value, Bits)
               then -Ty.Folded (Mask (0 - Value, Bits))
               else Ty.Folded (Value));

         --  How wide this expression folds.  Bool has no arithmetic width
         --  and folds at the byte the backend gives it -- the same rule
         --  the backend's own folder keeps.
         function Fold_Width
           (Kind : Ty.Scalar_Name) return Landin.Targets.Bit_Width
           is (if Kind in Ty.Integer_Name
               then Ty.Width (Ty.Integer_Name (Kind), Facts)
               else 8);

         function Is_Signed_Type (Kind : Ty.Scalar_Name) return Boolean
           is (Kind in Ty.Integer_Name
               and then Ty.Is_Signed (Ty.Integer_Name (Kind)));

         procedure Fold_Constant
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Value   : out Ty.Folded;
            Known   : out Boolean);

         procedure Fold_Scalar_Datum
           (Id    : Res.Declaration_Id;
            Value : out Ty.Folded;
            Known : out Boolean);

         function Static_Field_Target
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return IR.Item_Id;

         function Static_Field_Target
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return IR.Item_Id
         is
         begin
            if Syn.Kind (Of_Tree, Value) = Syn.Anonymous_Function then
               return Anonymous_Item (Of_Tree, Value);
            elsif Syn.Kind (Of_Tree, Value) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Value)
                = Res.Bound
            then
               declare
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Value);
               begin
                  if Res.Sort_Of (Meanings.all, Source_Id)
                       = Res.Module_Function
                  then
                     return IR.Item_For (Unit.all, Source_Id);
                  elsif Res.Sort_Of (Meanings.all, Source_Id)
                          = Res.Module_Binding
                    and then Landin.Checking.Type_Of
                      (Types.all, Source_Id) = Ty.Function_Value
                  then
                     return Static_Function_Target (Source_Id);
                  end if;
               end;
            end if;

            raise Landin.Compiler_Defect with
              "a static function field has no routine target";
         end Static_Field_Target;

         --  A per-datum guard against the fold following a [1940] cycle
         --  the checker's own fold guard did not report.  Deliberately a
         --  distinct set from Where above, because Fold_Scalar_Datum can
         --  reach a module binding that also owns an array image and the
         --  two questions travel through the same table.
         Folding : array (Numbered) of Boolean := [others => False];

         procedure Fold_Scalar_Datum
           (Id    : Res.Declaration_Id;
            Value : out Ty.Folded;
            Known : out Boolean)
         is
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Theirs : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
            Their_Value : constant Syn.Node_Id :=
              Syn.Value_Of (Their_Tree.all, Theirs);
         begin
            Value := 0;
            Known := False;

            if Folding (Id) then
               return;
            end if;

            if Their_Value = Syn.No_Node then
               --  D10 gives an omitted-initializer binding zero and False
               --  for a bool.  Either way, the folded value is zero.
               Value := 0;
               Known := True;
               return;
            end if;

            Folding (Id) := True;
            Fold_Constant (Their_Tree.all, Their_Value, Value, Known);
            Folding (Id) := False;
         end Fold_Scalar_Datum;

         procedure Fold_Constant
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Value   : out Ty.Folded;
            Known   : out Boolean)
         is
            procedure Combine
              (Left, Right : Ty.Folded;
               Of_Kind     : Syn.Node_Kind;
               Answer      : out Ty.Folded;
               Fits        : out Boolean);

            procedure Combine
              (Left, Right : Ty.Folded;
               Of_Kind     : Syn.Node_Kind;
               Answer      : out Ty.Folded;
               Fits        : out Boolean) is
            begin
               Answer := 0;
               Fits   := True;

               case Of_Kind is
                  when Syn.Add | Syn.Wrapping_Add =>
                     Fits := (if Right > 0
                              then Left <= Ty.Folded'Last - Right
                              else Left >= Ty.Folded'First - Right);

                  when Syn.Subtract | Syn.Wrapping_Subtract =>
                     Fits := (if Right > 0
                              then Left >= Ty.Folded'First + Right
                              else Left <= Ty.Folded'Last + Right);

                  when Syn.Multiply | Syn.Wrapping_Multiply =>
                     Fits := Left = 0
                             or else abs Right
                                     <= Ty.Folded'Last / abs Left;

                  when Syn.Divide | Syn.Remainder =>
                     Fits := Right /= 0;

                  when others =>
                     Fits := False;
               end case;

               if not Fits then
                  return;
               end if;

               case Of_Kind is
                  when Syn.Add | Syn.Wrapping_Add =>
                     Answer := Left + Right;
                  when Syn.Subtract | Syn.Wrapping_Subtract =>
                     Answer := Left - Right;
                  when Syn.Multiply | Syn.Wrapping_Multiply =>
                     Answer := Left * Right;
                  when Syn.Divide =>
                     Answer := Left / Right;
                  when Syn.Remainder =>
                     Answer := Left rem Right;
                  when others =>
                     Fits := False;
               end case;
            end Combine;
         begin
            Value := 0;
            Known := False;

            if Node = Syn.No_Node
              or else not Syn.Is_Sound (Of_Tree, Node)
            then
               return;
            end if;

            case Syn.Kind (Of_Tree, Node) is
               when Syn.Integer_Literal =>
                  declare
                     Snap : constant Landin.Source.Snapshot :=
                       Landin.Stages.Source
                         (Context, Syn.Source_Of (Of_Tree));
                     Text : constant String :=
                       Landin.Source.Slice
                         (Snap, Syn.Digit_Span (Of_Tree, Node));
                     Held       : Ty.Magnitude;
                     Overflowed : Boolean;
                  begin
                     Ty.Evaluate
                       (Text, Syn.Base (Of_Tree, Node), Held, Overflowed);

                     if not Overflowed then
                        Value := Ty.Folded (Held);
                        Known := True;
                     end if;
                  end;

               when Syn.True_Literal =>
                  Value := 1;
                  Known := True;

               when Syn.False_Literal =>
                  Value := 0;
                  Known := True;

               when Syn.Zeroed_Literal =>
                  --  D66 gives a labelled scalar `zeroed` its field type;
                  --  its target-neutral fold is the same zero pattern D42
                  --  uses at runtime.
                  Value := 0;
                  Known := True;

               when Syn.Negation =>
                  declare
                     Under : Ty.Folded;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Under, Known);
                     if Known then
                        Value := -Under;
                     end if;
                  end;

               when Syn.Name_Reference =>
                  if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                     = Res.Bound
                  then
                     declare
                        Means : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Node);
                     begin
                        if Res.Sort_Of (Meanings.all, Means)
                           = Res.Module_Binding
                          and then Landin.Checking.Type_Of
                                     (Types.all, Means)
                                   in Ty.Scalar_Name
                        then
                           Fold_Scalar_Datum (Means, Value, Known);
                        end if;
                     end;
                  end if;

               when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
                  | Syn.Remainder =>
                  declare
                     Left, Right : Ty.Folded;
                     Left_Known, Right_Known, Fits : Boolean;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     Fold_Constant
                       (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                        Right, Right_Known);
                     if Left_Known and then Right_Known then
                        Combine
                          (Left, Right, Syn.Kind (Of_Tree, Node),
                           Value, Fits);
                        Known := Fits;
                     end if;
                  end;

               --  [0300]'s wrapping arithmetic, [0330]'s bitwise set and
               --  [0320]'s shifts all depend on the operand type's width.
               --  Checking has already settled the same target-aware fold;
               --  this second walk records its verified answer in the image.
               when Syn.Wrapping_Add | Syn.Wrapping_Subtract
                  | Syn.Wrapping_Multiply
                  | Syn.Bitwise_And | Syn.Bitwise_Xor | Syn.Bitwise_Or
                  | Syn.Shift_Left | Syn.Shift_Right =>
                  declare
                     Op         : constant Syn.Node_Kind :=
                       Syn.Kind (Of_Tree, Node);
                     Left_Node  : constant Syn.Node_Id :=
                       Syn.Left_Of (Of_Tree, Node);
                     Right_Node : constant Syn.Node_Id :=
                       Syn.Right_Of (Of_Tree, Node);
                     Left       : Ty.Folded := 0;
                     Right      : Ty.Folded := 0;
                     Left_Known, Right_Known : Boolean := False;
                     Kind       : constant Ty.Type_Kind :=
                       Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     Fold_Constant (Of_Tree, Left_Node, Left, Left_Known);
                     Fold_Constant
                       (Of_Tree, Right_Node, Right, Right_Known);

                     if Left_Known and then Right_Known
                       and then Kind in Ty.Scalar_Name
                     then
                        declare
                           Bits : constant Landin.Targets.Bit_Width :=
                             Fold_Width (Ty.Scalar_Name (Kind));
                           Signed : constant Boolean :=
                             Is_Signed_Type (Ty.Scalar_Name (Kind));
                           LP : constant Pattern := To_Pattern (Left, Bits);
                           RP : constant Pattern := To_Pattern (Right, Bits);
                           Answer : Pattern := 0;
                           Exhausted : constant Boolean :=
                             Op in Syn.Shift_Left | Syn.Shift_Right
                               and then Right >= Ty.Folded (Bits);
                        begin
                           case Op is
                              when Syn.Wrapping_Add =>
                                 Answer := Mask (LP + RP, Bits);
                              when Syn.Wrapping_Subtract =>
                                 Answer := Mask (LP - RP, Bits);
                              when Syn.Wrapping_Multiply =>
                                 Answer := Mask (LP * RP, Bits);
                              when Syn.Bitwise_And =>
                                 Answer := Mask (LP and RP, Bits);
                              when Syn.Bitwise_Xor =>
                                 Answer := Mask (LP xor RP, Bits);
                              when Syn.Bitwise_Or =>
                                 Answer := Mask (LP or RP, Bits);
                              when Syn.Shift_Left =>
                                 Answer :=
                                   (if Exhausted then 0
                                    else Mask
                                           (LP * 2 ** Natural (Right),
                                            Bits));
                              when Syn.Shift_Right =>
                                 --  [0320]: signed `>>` preserves the sign
                                 --  and unsigned fills with zeros.  Mirror
                                 --  the backend's rule so the image is what
                                 --  a datum's loaded bytes would compute.
                                 Answer :=
                                   (if Exhausted then 0
                                    elsif Signed and then Left < 0
                                    then Mask
                                           (not
                                             (Mask (not LP, Bits)
                                              / 2 ** Natural (Right)),
                                            Bits)
                                    else Mask
                                           (LP / 2 ** Natural (Right),
                                            Bits));
                              when others =>
                                 raise Landin.Compiler_Defect with
                                   "unreachable width-op case";
                           end case;
                           Value := As_Number (Answer, Bits, Signed);
                           Known := True;
                        end;
                     end if;
                  end;

               when Syn.Complement =>
                  declare
                     Under : Ty.Folded := 0;
                     Under_Known : Boolean := False;
                     Kind : constant Ty.Type_Kind :=
                       Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Under, Under_Known);
                     if Under_Known and then Kind in Ty.Scalar_Name then
                        declare
                           Bits : constant Landin.Targets.Bit_Width :=
                             Fold_Width (Ty.Scalar_Name (Kind));
                           Signed : constant Boolean :=
                             Is_Signed_Type (Ty.Scalar_Name (Kind));
                        begin
                           Value :=
                             As_Number
                               (Mask
                                  (not To_Pattern (Under, Bits), Bits),
                                Bits, Signed);
                           Known := True;
                        end;
                     end if;
                  end;

               when Syn.Logical_Not =>
                  declare
                     Under : Ty.Folded := 0;
                     Under_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Under, Under_Known);
                     if Under_Known then
                        Value := 1 - Under;
                        Known := True;
                     end if;
                  end;

               when Syn.Logical_And =>
                  --  [0410]: `and` short-circuits.  A false left settles
                  --  the answer without evaluating the right, which is
                  --  the same rule the checker's own module value fold
                  --  keeps for the same reason -- the right may not fold.
                  declare
                     Left : Ty.Folded := 0;
                     Left_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     if Left_Known and then Left = 0 then
                        Value := 0;
                        Known := True;
                     elsif Left_Known then
                        declare
                           Right : Ty.Folded := 0;
                           Right_Known : Boolean := False;
                        begin
                           Fold_Constant
                             (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                              Right, Right_Known);
                           if Right_Known then
                              Value := Right;
                              Known := True;
                           end if;
                        end;
                     end if;
                  end;

               when Syn.Logical_Or =>
                  declare
                     Left : Ty.Folded := 0;
                     Left_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     if Left_Known and then Left = 1 then
                        Value := 1;
                        Known := True;
                     elsif Left_Known then
                        declare
                           Right : Ty.Folded := 0;
                           Right_Known : Boolean := False;
                        begin
                           Fold_Constant
                             (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                              Right, Right_Known);
                           if Right_Known then
                              Value := Right;
                              Known := True;
                           end if;
                        end;
                     end if;
                  end;

               when Syn.Equal_To | Syn.Not_Equal_To
                  | Syn.Less_Than | Syn.Less_Or_Equal
                  | Syn.Greater_Than | Syn.Greater_Or_Equal =>
                  declare
                     Op : constant Syn.Node_Kind :=
                       Syn.Kind (Of_Tree, Node);
                     Left, Right : Ty.Folded := 0;
                     Left_Known, Right_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     Fold_Constant
                       (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                        Right, Right_Known);
                     if Left_Known and then Right_Known then
                        Value :=
                          (case Op is
                              when Syn.Equal_To =>
                                (if Left = Right then 1 else 0),
                              when Syn.Not_Equal_To =>
                                (if Left /= Right then 1 else 0),
                              when Syn.Less_Than =>
                                (if Left < Right then 1 else 0),
                              when Syn.Less_Or_Equal =>
                                (if Left <= Right then 1 else 0),
                              when Syn.Greater_Than =>
                                (if Left > Right then 1 else 0),
                              when others =>
                                (if Left >= Right then 1 else 0));
                        Known := True;
                     end if;
                  end;

               when Syn.Size_Of | Syn.Align_Of =>
                  --  [0370]: a measurement of an enabled type folds to the
                  --  target's own byte count; the whole point of it being
                  --  a `usize` is that a target answers.  D44's aggregate
                  --  answer is the checked target layout here because this
                  --  walk is forming a static datum image, not ordinary IR.
                  declare
                     Asked : constant Syn.Node_Id :=
                       Syn.Measured_Type (Of_Tree, Node);
                     Held : constant Ty.Type_Kind :=
                       Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Asked);
                  begin
                     if Held in Ty.Scalar_Name then
                        declare
                           Size : constant Landin.Targets.Scalar_Size :=
                             Ty.Storage_Size
                               (Ty.Scalar_Name (Held), Facts);
                        begin
                           if Syn.Kind (Of_Tree, Node) = Syn.Size_Of then
                              Value :=
                                Ty.Folded
                                  (Landin.Targets.Bytes (Size));
                           else
                              Value :=
                                Ty.Folded
                                  (Landin.Targets.Alignment_Of
                                     (Facts, Size));
                           end if;
                           Known := True;
                        end;
                     elsif Held = Ty.Fixed_Array then
                        declare
                           Length : constant Landin.Checking.Element_Count
                             :=
                               Landin.Checking.Array_Length
                                 (Types.all, Of_Tree, Asked);
                           Element : constant Ty.Scalar_Name :=
                             Landin.Checking.Array_Element
                               (Types.all, Of_Tree, Asked);
                           Size : constant Landin.Targets.Scalar_Size :=
                             Ty.Storage_Size (Element, Facts);
                        begin
                           if Syn.Kind (Of_Tree, Node) = Syn.Align_Of then
                              Value :=
                                (if Length = 0 then 1
                                 else Ty.Folded
                                        (Landin.Targets.Alignment_Of
                                           (Facts, Size)));
                           else
                              Value :=
                                Ty.Folded
                                  (Landin.Targets.Byte_Count (Length)
                                   * Landin.Targets.Byte_Count
                                       (Landin.Targets.Bytes (Size)));
                           end if;
                           Known := True;
                        end;
                     elsif Held = Ty.Aggregate then
                        declare
                           Declared : constant
                             Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Nominal_Of
                               (Types.all, Of_Tree, Asked);
                        begin
                           Value :=
                             Ty.Folded
                               (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                                then Landin.Checking.Layout_Size
                                       (Types.all, Declared)
                                else Landin.Checking.Layout_Alignment
                                       (Types.all, Declared));
                           Known := True;
                        end;
                     end if;
                  end;

               when Syn.Len_Of =>
                  --  [0370]'s length lives on the type, not on storage.
                  declare
                     Asked : constant Syn.Node_Id :=
                       Syn.Operand_Of (Of_Tree, Node);
                  begin
                     if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                        Value :=
                          Ty.Folded (Syn.Element_Count (Of_Tree, Asked));
                        Known := True;
                     elsif Syn.Kind (Of_Tree, Asked) = Syn.Name_Reference
                       and then Res.Verdict_Of
                                  (Meanings.all, Of_Tree, Asked)
                                = Res.Bound
                     then
                        declare
                           Named : constant Res.Declaration_Id :=
                             Res.Bound_To
                               (Meanings.all, Of_Tree, Asked);
                        begin
                           if Landin.Checking.Type_Of
                                (Types.all, Named) = Ty.Fixed_Array
                           then
                              Value :=
                                Ty.Folded
                                  (Landin.Checking.Array_Length
                                     (Types.all, Named));
                              Known := True;
                           end if;
                        end;
                     end if;
                  end;

               when others =>
                  --  A construct outside D24's boundary.  The checker
                  --  refused everything else that could reach here, so
                  --  meeting one is a compiler defect rather than a
                  --  diagnosis.
                  raise Landin.Compiler_Defect with
                    "a module array literal element the lowering cannot"
                    & " fold reached image resolution";
            end case;
         end Fold_Constant;

         procedure Set_Image_From_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id);

         procedure Set_Image_From_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id)
         is
            Count : constant Natural :=
              Syn.Element_Count (Of_Tree, Literal);
         begin
            if Count = 0 then
               return;
            end if;

            declare
               Values : Ty.Folded_Array (1 .. Count) := [others => 0];
               Held   : Ty.Folded;
               Known  : Boolean;
            begin
               for Position in 1 .. Count loop
                  Fold_Constant
                    (Of_Tree,
                     Syn.Nth_Element (Of_Tree, Literal, Position),
                     Held, Known);
                  if not Known then
                     raise Landin.Compiler_Defect with
                       "a module array literal element the checker"
                       & " accepted did not fold at lowering";
                  end if;
                  Values (Position) := Held;
               end loop;

               IR.Set_Array_Image
                 (Unit.all, IR.Item_For (Unit.all, Id), Values);
               Made (Id) := True;
            end;
         end Set_Image_From_Literal;

         procedure Set_Image_From_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id);

         procedure Set_Image_From_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id)
         is
            Held  : Ty.Folded;
            Known : Boolean;
         begin
            Fold_Constant
              (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition),
               Held, Known);
            if not Known then
               raise Landin.Compiler_Defect with
                 "a module array repetition element the checker accepted"
                 & " did not fold at lowering";
            end if;

            --  D34's zero pattern is loader-zeroed storage, represented by
            --  the same absent image as D10 and `zeroed`.  Every nonzero
            --  extent is one scalar plus the compact D17 shape.
            if Held /= 0 then
               IR.Set_Repeated_Array_Image
                 (Unit.all, IR.Item_For (Unit.all, Id), Held);
               Made (Id) := True;
            end if;
         end Set_Image_From_Repetition;

         procedure Set_Image_From_Mixed_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id);

         procedure Set_Image_From_Mixed_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id)
         is
            Count : constant Natural :=
              Syn.Element_Count (Of_Tree, Repetition);
            Values : Ty.Folded_Array (1 .. Count) := [others => 0];
            Held  : Ty.Folded;
            Known : Boolean;
         begin
            for Position in Values'Range loop
               Fold_Constant
                 (Of_Tree,
                  Syn.Nth_Element (Of_Tree, Repetition, Position),
                  Held, Known);
               if not Known then
                  raise Landin.Compiler_Defect with
                    "a module mixed repetition prefix the checker accepted"
                    & " did not fold at lowering";
               end if;
               Values (Position) := Held;
            end loop;

            Fold_Constant
              (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition),
               Held, Known);
            if not Known then
               raise Landin.Compiler_Defect with
                 "a module mixed repetition suffix the checker accepted"
                 & " did not fold at lowering";
            end if;

            --  D38 always records the hybrid, including a zero suffix.  Its
            --  finite prefix makes the datum an explicit `.data` image.
            IR.Set_Hybrid_Array_Image
              (Unit.all, IR.Item_For (Unit.all, Id), Values, Held);
            Made (Id) := True;
         end Set_Image_From_Mixed_Repetition;

         --  D69's struct-literal field may name an array datum declared
         --  later, so its image must be resolved before the aggregate image
         --  gathers that field's compact descriptor.
         procedure Resolve_Image (Id : Res.Declaration_Id);

         procedure Copy_Field_Descriptor
           (Source_Item  : IR.Item_Id;
            Source_Field : Positive;
            Cursor       : in out Natural;
            Image        : out IR.Aggregate_Field_Image;
            Elements     : in out Ty.Folded_Array);

         function Array_Image_Element_Count
           (Source_Item : IR.Item_Id) return Natural;

         procedure Copy_Array_Descriptor
           (Source_Item : IR.Item_Id;
            Cursor      : in out Natural;
            Image       : out IR.Aggregate_Field_Image;
            Elements    : in out Ty.Folded_Array);

         function Array_Image_Element_Count
           (Source_Item : IR.Item_Id) return Natural
         is
         begin
            return
              (if IR.Is_Repeated_Image (Unit.all, Source_Item)
               then Natural
                 (IR.Image_Prefix_Length (Unit.all, Source_Item))
               else Natural (IR.Image_Length (Unit.all, Source_Item)));
         end Array_Image_Element_Count;

         procedure Copy_Array_Descriptor
           (Source_Item : IR.Item_Id;
            Cursor      : in out Natural;
            Image       : out IR.Aggregate_Field_Image;
            Elements    : in out Ty.Folded_Array)
         is
         begin
            Image := (others => <>);
            Image.Offset := Cursor;

            if IR.Is_Repeated_Image (Unit.all, Source_Item) then
               Image.Count := Natural
                 (IR.Image_Prefix_Length (Unit.all, Source_Item));
               Image.Form :=
                 (if Image.Count = 0 then IR.Repeated else IR.Hybrid);
               Image.Value :=
                 IR.Repeated_Image_Value (Unit.all, Source_Item);
            else
               Image.Count := Natural
                 (IR.Image_Length (Unit.all, Source_Item));
               Image.Form := IR.Finite;
            end if;

            for Position in 1 .. Image.Count loop
               Elements (Cursor + Position) :=
                 IR.Nth_Image
                   (Unit.all, Source_Item, IR.Part_Position (Position));
            end loop;
            Cursor := Cursor + Image.Count;
         end Copy_Array_Descriptor;

         procedure Copy_Field_Descriptor
           (Source_Item  : IR.Item_Id;
            Source_Field : Positive;
            Cursor       : in out Natural;
            Image        : out IR.Aggregate_Field_Image;
            Elements     : in out Ty.Folded_Array)
         is
         begin
            Image :=
              IR.Field_Image_Of (Unit.all, Source_Item, Source_Field);
            Image.Offset := Cursor;

            if Image.Form in IR.Finite | IR.Hybrid then
               for Position in 1 .. Image.Count loop
                  Elements (Cursor + Position) :=
                    IR.Nth_Field_Element
                      (Unit.all, Source_Item, Source_Field,
                       IR.Part_Position (Position));
               end loop;
            elsif Image.Count /= 0 then
               raise Landin.Compiler_Defect with
                 "an absent or repeated aggregate field image carried"
                 & " finite elements";
            end if;

            Cursor := Cursor + Image.Count;
         end Copy_Field_Descriptor;

         --  D132 recursively carries a written ordinary-child image in the
         --  same item-owned descriptor and fold runs D67/D81 already use.
         --  A Nested descriptor points to one contiguous direct-child run;
         --  those children may point farther into the run in turn.  Every
         --  offset below is therefore a descriptor or fold index, never a
         --  target byte position.
         procedure Set_Recursive_Image_From_Struct_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id);

         procedure Set_Recursive_Image_From_Struct_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id)
         is
            Item : constant IR.Item_Id := IR.Item_For (Unit.all, Id);
            Top_Count : constant Natural := IR.Field_Count (Unit.all, Item);
            Values : Ty.Folded_Array (1 .. Top_Count) := [others => 0];
            Descriptors : Descriptor_Vectors.Vector;
            Elements : Fold_Vectors.Vector;

            function Element_Cursor return Natural
              is (Natural (Elements.Length));

            function Descendant_Cursor return Natural
              is (Natural (Descriptors.Length) - Top_Count);

            procedure Put
              (Position : Positive; Image : IR.Aggregate_Field_Image);

            function Reserve_Children
              (Position : Positive;
               Form     : IR.Field_Image_Form;
               Count    : Positive;
               Value    : Ty.Folded := 0) return Positive;

            procedure Build_Field
              (Shape     : IR.Field_Shape;
               Given     : Syn.Node_Id;
               Position  : Positive;
               Top_Field : Natural := 0);

            procedure Clone_Field
              (Source_Item  : IR.Item_Id;
               Shape        : IR.Field_Shape;
               Source_Image : IR.Aggregate_Field_Image;
               Position     : Positive);

            procedure Clone_Array
              (Source_Item  : IR.Item_Id;
               Source_Image : IR.Aggregate_Field_Image;
               Position     : Positive);

            procedure Clone_Aggregate_Root
              (Source_Item : IR.Item_Id;
               Position    : Positive);

            procedure Copy_Aggregate_Value
              (Given    : Syn.Node_Id;
               Position : Positive);

            procedure Build_Array
              (Shape    : IR.Field_Shape;
               Given    : Syn.Node_Id;
               Position : Positive);

            procedure Build_Aggregate
              (Shape    : IR.Field_Shape;
               Given    : Syn.Node_Id;
               Position : Positive);

            procedure Build_Variant
              (Shape    : IR.Field_Shape;
               Given    : Syn.Node_Id;
               Position : Positive);

            procedure Put
              (Position : Positive; Image : IR.Aggregate_Field_Image)
            is
            begin
               Descriptors.Replace_Element (Position, Image);
            end Put;

            function Reserve_Children
              (Position : Positive;
               Form     : IR.Field_Image_Form;
               Count    : Positive;
               Value    : Ty.Folded := 0) return Positive
            is
               Offset : constant Natural := Descendant_Cursor;
            begin
               Put
                 (Position,
                  (Form   => Form,
                   Offset => Offset,
                   Count  => Count,
                   Value  => Value,
                   others => <>));
               for Child in 1 .. Count loop
                  Descriptors.Append
                    (IR.Aggregate_Field_Image'(others => <>));
               end loop;
               return Positive (Top_Count + Offset + 1);
            end Reserve_Children;

            procedure Clone_Array
              (Source_Item  : IR.Item_Id;
               Source_Image : IR.Aggregate_Field_Image;
               Position     : Positive)
            is
               Image : IR.Aggregate_Field_Image := Source_Image;
            begin
               Image.Offset := Element_Cursor;
               Put (Position, Image);
               if Image.Form in IR.Finite | IR.Hybrid then
                  for Element in 1 .. Image.Count loop
                     Elements.Append
                       (IR.Nth_Descriptor_Element
                          (Unit.all, Source_Item, Source_Image,
                           IR.Part_Position (Element)));
                  end loop;
               end if;
            end Clone_Array;

            procedure Clone_Field
              (Source_Item  : IR.Item_Id;
               Shape        : IR.Field_Shape;
               Source_Image : IR.Aggregate_Field_Image;
               Position     : Positive)
            is
            begin
               case Shape.Kind is
                  when IR.Scalar_Field_Shape =>
                     Put
                       (Position,
                        (Form   => IR.Absent,
                         Offset => Element_Cursor,
                         Count  => 0,
                         Value  => Source_Image.Value,
                         Target => Source_Image.Target));

                  when IR.Array_Field_Shape =>
                     Clone_Array
                       (Source_Item, Source_Image, Position);

                  when IR.Aggregate_Field_Shape =>
                     if Source_Image.Form = IR.Absent then
                        Put
                          (Position,
                           (Form   => IR.Absent,
                            Offset => Descendant_Cursor,
                            Count  => 0,
                            Value  => 0,
                            others => <>));
                     elsif Source_Image.Form = IR.Nested then
                        declare
                           Count : constant Natural :=
                             IR.Aggregate_Field_Count (Unit.all, Shape);
                           First : constant Positive :=
                             Reserve_Children
                               (Position, IR.Nested, Positive (Count));
                        begin
                           if Source_Image.Count /= Count then
                              raise Landin.Compiler_Defect with
                                "a verified nested module image changed"
                                & " child count during lowering";
                           end if;
                           for Child in 1 .. Count loop
                              Clone_Field
                                (Source_Item,
                                 IR.Nth_Aggregate_Field
                                   (Unit.all, Shape, Child),
                                 IR.Descendant_Image_Of
                                   (Unit.all, Source_Item, Source_Image,
                                    Child),
                                 First + Child - 1);
                           end loop;
                        end;
                     else
                        raise Landin.Compiler_Defect with
                          "a non-nested descriptor reached an ordinary"
                          & " child module image";
                     end if;

                  when IR.Variant_Field_Shape =>
                     if Source_Image.Form = IR.Absent then
                        Put
                          (Position,
                           (Form   => IR.Absent,
                            Offset => Descendant_Cursor,
                            Count  => 0,
                            Value  => 0,
                            others => <>));
                     elsif Source_Image.Form = IR.Selected then
                        declare
                           Selected : constant Positive :=
                             Positive (Source_Image.Value);
                           Count : constant Natural :=
                             IR.Variant_Case_Field_Count
                               (Unit.all, Shape, Selected);
                           First : constant Positive :=
                             Reserve_Children
                               (Position, IR.Selected, Positive (Count),
                                Source_Image.Value);
                        begin
                           if Source_Image.Count /= Count then
                              raise Landin.Compiler_Defect with
                                "a verified selected module image changed"
                                & " payload count during lowering";
                           end if;
                           for Payload in 1 .. Count loop
                              Clone_Field
                                (Source_Item,
                                 IR.Nth_Variant_Case_Field
                                   (Unit.all, Shape, Selected, Payload),
                                 IR.Descendant_Image_Of
                                   (Unit.all, Source_Item, Source_Image,
                                    Payload),
                                 First + Payload - 1);
                           end loop;
                        end;
                     else
                        raise Landin.Compiler_Defect with
                          "a non-selected descriptor reached a variant"
                          & " module image";
                     end if;
               end case;
            end Clone_Field;

            procedure Clone_Aggregate_Root
              (Source_Item : IR.Item_Id;
               Position    : Positive)
            is
            begin
               if not IR.Has_Image (Unit.all, Source_Item) then
                  Put
                    (Position,
                     (Form   => IR.Absent,
                      Offset => Descendant_Cursor,
                      Count  => 0,
                      Value  => 0,
                      others => <>));
                  return;
               end if;

               declare
                  Count : constant Natural :=
                    IR.Field_Count (Unit.all, Source_Item);
                  First : constant Positive :=
                    Reserve_Children
                      (Position, IR.Nested, Positive (Count));
               begin
                  for Field in 1 .. Count loop
                     declare
                        Shape : constant IR.Field_Shape :=
                          IR.Nth_Field_Shape
                            (Unit.all, Source_Item, Field);
                        Target : constant Positive := First + Field - 1;
                     begin
                        if Shape.Kind = IR.Scalar_Field_Shape then
                           declare
                              Image : constant IR.Aggregate_Field_Image :=
                                IR.Field_Image_Of
                                  (Unit.all, Source_Item, Field);
                           begin
                              Put
                                (Target,
                                 (Form   => IR.Absent,
                                  Offset => Element_Cursor,
                                  Count  => 0,
                                  Value  => IR.Nth_Field_Image
                                    (Unit.all, Source_Item, Field),
                                  Target => Image.Target));
                           end;
                        else
                           Clone_Field
                             (Source_Item, Shape,
                              IR.Field_Image_Of
                                (Unit.all, Source_Item, Field),
                              Target);
                        end if;
                     end;
                  end loop;
               end;
            end Clone_Aggregate_Root;

            procedure Copy_Aggregate_Value
              (Given    : Syn.Node_Id;
               Position : Positive)
            is
               Source_Id : Res.Declaration_Id := Res.No_Declaration;
               Source_Field : Natural := 0;
            begin
               if Syn.Kind (Of_Tree, Given) = Syn.Name_Reference then
                  Source_Id := Res.Bound_To
                    (Meanings.all, Of_Tree, Given);
               elsif Syn.Kind (Of_Tree, Given) = Syn.Member_Selection then
                  Source_Id := Res.Bound_To
                    (Meanings.all, Of_Tree,
                     Syn.Target_Of (Of_Tree, Given));
                  Source_Field := Landin.Checking.Field_Index
                    (Types.all, Of_Tree, Given);
               else
                  raise Landin.Compiler_Defect with
                    "a non-storage ordinary-child image reached lowering";
               end if;

               Resolve_Image (Source_Id);
               if not Made (Source_Id) then
                  Put
                    (Position,
                     (Form   => IR.Absent,
                      Offset => Descendant_Cursor,
                      Count  => 0,
                      Value  => 0,
                      others => <>));
                  return;
               end if;

               declare
                  Source_Item : constant IR.Item_Id :=
                    IR.Item_For (Unit.all, Source_Id);
               begin
                  if Source_Field = 0 then
                     Clone_Aggregate_Root (Source_Item, Position);
                  else
                     declare
                        Shape : constant IR.Field_Shape :=
                          IR.Nth_Field_Shape
                            (Unit.all, Source_Item, Source_Field);
                     begin
                        Clone_Field
                          (Source_Item, Shape,
                           IR.Field_Image_Of
                             (Unit.all, Source_Item, Source_Field),
                           Position);
                     end;
                  end if;
               end;
            end Copy_Aggregate_Value;

            procedure Build_Array
              (Shape    : IR.Field_Shape;
               Given    : Syn.Node_Id;
               Position : Positive)
            is
               Image : IR.Aggregate_Field_Image :=
                 (Form   => IR.Absent,
                  Offset => Element_Cursor,
                  Count  => 0,
                  Value  => 0,
                  others => <>);
               Held : Ty.Folded;
               Known : Boolean;
            begin
               if Given = Syn.No_Node
                 or else Syn.Kind (Of_Tree, Given) = Syn.Zeroed_Literal
               then
                  Put (Position, Image);
                  return;
               end if;

               case Syn.Kind (Of_Tree, Given) is
                  when Syn.Array_Literal | Syn.Mixed_Array_Repetition =>
                     Image.Form :=
                       (if Syn.Kind (Of_Tree, Given) = Syn.Array_Literal
                        then IR.Finite else IR.Hybrid);
                     Image.Count := Syn.Element_Count (Of_Tree, Given);
                     Put (Position, Image);
                     for Element in 1 .. Image.Count loop
                        Fold_Constant
                          (Of_Tree,
                           Syn.Nth_Element (Of_Tree, Given, Element),
                           Held, Known);
                        if not Known then
                           raise Landin.Compiler_Defect with
                             "a checked nested array image did not fold";
                        end if;
                        Elements.Append (Held);
                     end loop;
                     if Image.Form = IR.Hybrid then
                        Fold_Constant
                          (Of_Tree, Syn.Repeated_Element (Of_Tree, Given),
                           Held, Known);
                        if not Known then
                           raise Landin.Compiler_Defect with
                             "a checked nested hybrid suffix did not fold";
                        end if;
                        Image.Value := Held;
                        Put (Position, Image);
                     end if;

                  when Syn.Array_Repetition =>
                     Fold_Constant
                       (Of_Tree, Syn.Repeated_Element (Of_Tree, Given),
                        Held, Known);
                     if not Known then
                        raise Landin.Compiler_Defect with
                          "a checked nested repetition did not fold";
                     end if;
                     if Held /= 0 then
                        Image.Form := IR.Repeated;
                        Image.Value := Held;
                     end if;
                     Put (Position, Image);

                  when Syn.Name_Reference =>
                     declare
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Given);
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id) then
                           declare
                              Source_Item : constant IR.Item_Id :=
                                IR.Item_For (Unit.all, Source_Id);
                           begin
                              if IR.Is_Repeated_Image
                                (Unit.all, Source_Item)
                              then
                                 Image.Form :=
                                   (if IR.Image_Prefix_Length
                                        (Unit.all, Source_Item) = 0
                                    then IR.Repeated else IR.Hybrid);
                                 Image.Value := IR.Repeated_Image_Value
                                   (Unit.all, Source_Item);
                                 Image.Count := Natural
                                   (IR.Image_Prefix_Length
                                      (Unit.all, Source_Item));
                              else
                                 Image.Form := IR.Finite;
                                 Image.Count := Natural
                                   (IR.Image_Length
                                      (Unit.all, Source_Item));
                              end if;
                              Put (Position, Image);
                              for Element in 1 .. Image.Count loop
                                 Elements.Append
                                   (IR.Nth_Image
                                      (Unit.all, Source_Item,
                                       IR.Part_Position (Element)));
                              end loop;
                           end;
                        else
                           Put (Position, Image);
                        end if;
                     end;

                  when Syn.Member_Selection =>
                     declare
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To
                            (Meanings.all, Of_Tree,
                             Syn.Target_Of (Of_Tree, Given));
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id) then
                           declare
                              Source_Item : constant IR.Item_Id :=
                                IR.Item_For (Unit.all, Source_Id);
                              Source_Image : constant
                                IR.Aggregate_Field_Image :=
                                  IR.Field_Image_Of
                                    (Unit.all, Source_Item,
                                     Positive
                                       (Landin.Checking.Field_Index
                                          (Types.all, Of_Tree, Given)));
                           begin
                              Clone_Array
                                (Source_Item, Source_Image, Position);
                           end;
                        else
                           Put (Position, Image);
                        end if;
                     end;

                  when others =>
                     raise Landin.Compiler_Defect with
                       "an unsupported nested array image reached lowering";
               end case;
               pragma Assert (Shape.Kind = IR.Array_Field_Shape);
            end Build_Array;

            procedure Build_Aggregate
              (Shape    : IR.Field_Shape;
               Given    : Syn.Node_Id;
               Position : Positive)
            is
            begin
               if Given = Syn.No_Node
                 or else Syn.Kind (Of_Tree, Given) = Syn.Zeroed_Literal
               then
                  Put
                    (Position,
                     (Form   => IR.Absent,
                      Offset => Descendant_Cursor,
                      Count  => 0,
                      Value  => 0,
                      others => <>));
               elsif Is_Struct_Construction (Of_Tree, Given) then
                  declare
                     Count : constant Natural :=
                       IR.Aggregate_Field_Count (Unit.all, Shape);
                     First : constant Positive :=
                       Reserve_Children
                         (Position, IR.Nested, Positive (Count));
                     type Node_Array is
                       array (Positive range <>) of Syn.Node_Id;
                     Nodes : Node_Array (1 .. Count) :=
                       [others => Syn.No_Node];
                  begin
                     for Written in
                       1 .. Construction_Field_Count (Of_Tree, Given)
                     loop
                        declare
                           Label : constant Syn.Node_Id :=
                             Nth_Construction_Field
                               (Of_Tree, Given, Written);
                        begin
                           Nodes
                             (Positive
                                (Landin.Checking.Field_Index
                                   (Types.all, Of_Tree, Label))) :=
                                     Construction_Field_Value
                                       (Of_Tree, Label);
                        end;
                     end loop;
                     for Child in 1 .. Count loop
                        Build_Field
                          (IR.Nth_Aggregate_Field
                             (Unit.all, Shape, Child),
                           Nodes (Child), First + Child - 1);
                     end loop;
                  end;
               else
                  Copy_Aggregate_Value (Given, Position);
               end if;
            end Build_Aggregate;

            procedure Build_Variant
              (Shape    : IR.Field_Shape;
               Given    : Syn.Node_Id;
               Position : Positive)
            is
            begin
               if Given = Syn.No_Node
                 or else Syn.Kind (Of_Tree, Given) = Syn.Zeroed_Literal
               then
                  Put
                    (Position,
                     (Form   => IR.Absent,
                      Offset => Descendant_Cursor,
                      Count  => 0,
                      Value  => 0,
                      others => <>));
                  return;
               end if;

               declare
                  Selected : constant Positive := Positive
                    (Landin.Checking.Field_Index
                       (Types.all, Of_Tree, Given));
                  Count : constant Natural :=
                    IR.Variant_Case_Field_Count
                      (Unit.all, Shape, Selected);
               begin
                  if Count = 0 then
                     Put
                       (Position,
                        (Form   => IR.Selected,
                         Offset => Descendant_Cursor,
                         Count  => 0,
                         Value  => Ty.Folded (Selected),
                         others => <>));
                     return;
                  end if;

                  declare
                     First : constant Positive :=
                       Reserve_Children
                         (Position, IR.Selected, Positive (Count),
                          Ty.Folded (Selected));
                     type Node_Array is
                       array (Positive range <>) of Syn.Node_Id;
                     Nodes : Node_Array (1 .. Count) :=
                       [others => Syn.No_Node];
                  begin
                     if Is_Case_Construction (Of_Tree, Given) then
                        for Written in
                          1 .. Construction_Field_Count (Of_Tree, Given)
                        loop
                           declare
                              Label : constant Syn.Node_Id :=
                                Nth_Construction_Field
                                  (Of_Tree, Given, Written);
                           begin
                              Nodes
                                (Positive
                                   (Landin.Checking.Field_Index
                                      (Types.all, Of_Tree, Label))) :=
                                        Construction_Field_Value
                                          (Of_Tree, Label);
                           end;
                        end loop;
                     end if;
                     for Payload in 1 .. Count loop
                        Build_Field
                          (IR.Nth_Variant_Case_Field
                             (Unit.all, Shape, Selected, Payload),
                           Nodes (Payload), First + Payload - 1);
                     end loop;
                  end;
               end;
            end Build_Variant;

            procedure Build_Field
              (Shape     : IR.Field_Shape;
               Given     : Syn.Node_Id;
               Position  : Positive;
               Top_Field : Natural := 0)
            is
               Held : Ty.Folded := 0;
               Known : Boolean := True;
               Target : IR.Item_Id := IR.No_Item;
            begin
               case Shape.Kind is
                  when IR.Scalar_Field_Shape =>
                     if Shape.Signature /= IR.No_Signature then
                        if Given = Syn.No_Node
                          or else Syn.Kind (Of_Tree, Given)
                                    = Syn.Zeroed_Literal
                        then
                           raise Landin.Compiler_Defect with
                             "a function-valued nested image has no target";
                        end if;
                        Target := Static_Field_Target (Of_Tree, Given);
                     elsif Given /= Syn.No_Node
                       and then Syn.Kind (Of_Tree, Given)
                                  /= Syn.Zeroed_Literal
                     then
                        Fold_Constant (Of_Tree, Given, Held, Known);
                        if not Known then
                           raise Landin.Compiler_Defect with
                             "a checked nested scalar image did not fold";
                        end if;
                     end if;
                     Put
                       (Position,
                        (Form   => IR.Absent,
                         Offset => Element_Cursor,
                         Count  => 0,
                         Value  =>
                           (if Top_Field = 0 then Held else 0),
                         Target => Target));
                     if Top_Field /= 0 then
                        Values (Top_Field) := Held;
                     end if;

                  when IR.Array_Field_Shape =>
                     Build_Array (Shape, Given, Position);

                  when IR.Aggregate_Field_Shape =>
                     Build_Aggregate (Shape, Given, Position);

                  when IR.Variant_Field_Shape =>
                     Build_Variant (Shape, Given, Position);
               end case;
            end Build_Field;
         begin
            for Field in 1 .. Top_Count loop
               Descriptors.Append
                 (IR.Aggregate_Field_Image'(others => <>));
            end loop;

            declare
               type Node_Array is array (Positive range <>) of Syn.Node_Id;
               Nodes : Node_Array (1 .. Top_Count) :=
                 [others => Syn.No_Node];
            begin
               for Written in
                 1 .. Construction_Field_Count (Of_Tree, Literal)
               loop
                  declare
                     Label : constant Syn.Node_Id :=
                       Nth_Construction_Field (Of_Tree, Literal, Written);
                  begin
                     Nodes
                       (Positive
                          (Landin.Checking.Field_Index
                             (Types.all, Of_Tree, Label))) :=
                               Construction_Field_Value (Of_Tree, Label);
                  end;
               end loop;

               for Field in 1 .. Top_Count loop
                  Build_Field
                    (IR.Nth_Field_Shape (Unit.all, Item, Field),
                     Nodes (Field), Field, Top_Field => Field);
               end loop;
            end;

            declare
               Descendant_Count : constant Natural := Descendant_Cursor;
               Element_Count : constant Natural := Element_Cursor;
               Images : IR.Aggregate_Field_Image_Array (1 .. Top_Count) :=
                 [others => (others => <>)];
               Descendants : IR.Aggregate_Field_Image_Array
                 (1 .. Descendant_Count) := [others => (others => <>)];
               Folds : Ty.Folded_Array (1 .. Element_Count) :=
                 [others => 0];
            begin
               for Field in Images'Range loop
                  Images (Field) := Descriptors (Field);
               end loop;
               for Child in Descendants'Range loop
                  Descendants (Child) :=
                    Descriptors (Top_Count + Child);
               end loop;
               for Element in Folds'Range loop
                  Folds (Element) := Elements (Element);
               end loop;
               IR.Set_Aggregate_Image
                 (Unit.all, Item, Values, Images, Descendants, Folds);
               Made (Id) := True;
            end;
         end Set_Recursive_Image_From_Struct_Literal;

         procedure Set_Image_From_Struct_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id);

         procedure Set_Image_From_Struct_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id)
         is
            Item : constant IR.Item_Id := IR.Item_For (Unit.all, Id);
            Count : constant Natural := IR.Field_Count (Unit.all, Item);
            type Node_Array is array (Positive range <>) of Syn.Node_Id;
            Nodes : Node_Array (1 .. Count) := [others => Syn.No_Node];
            Element_Count : Natural := 0;
            Payload_Count : Natural := 0;

            function Contains_Aggregate
              (Shape : IR.Field_Shape) return Boolean;

            function Contains_Aggregate
              (Shape : IR.Field_Shape) return Boolean
            is
            begin
               if Shape.Kind = IR.Aggregate_Field_Shape then
                  return True;
               elsif Shape.Kind = IR.Variant_Field_Shape then
                  for Variant_Case in 1 .. Shape.Cases loop
                     for Payload in
                       1 .. IR.Variant_Case_Field_Count
                              (Unit.all, Shape, Variant_Case)
                     loop
                        if Contains_Aggregate
                          (IR.Nth_Variant_Case_Field
                             (Unit.all, Shape, Variant_Case, Payload))
                        then
                           return True;
                        end if;
                     end loop;
                  end loop;
               end if;
               return False;
            end Contains_Aggregate;

            function Needs_Recursive_Image return Boolean;

            function Needs_Recursive_Image return Boolean is
            begin
               for Field in 1 .. Count loop
                  if Contains_Aggregate
                    (IR.Nth_Field_Shape (Unit.all, Item, Field))
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end Needs_Recursive_Image;
         begin
            if Needs_Recursive_Image then
               Set_Recursive_Image_From_Struct_Literal
                 (Id, Of_Tree, Literal);
               return;
            end if;

            for Position in
              1 .. Construction_Field_Count (Of_Tree, Literal)
            loop
               declare
                  Field : constant Syn.Node_Id :=
                    Nth_Construction_Field (Of_Tree, Literal, Position);
                  Which : constant Positive :=
                    Landin.Checking.Field_Index
                      (Types.all, Of_Tree, Field);
               begin
                  Nodes (Which) := Field;
                  if IR.Nth_Field_Shape
                       (Unit.all, Item, Which).Kind
                       = IR.Variant_Field_Shape
                  then
                     declare
                        Value : constant Syn.Node_Id :=
                          Construction_Field_Value (Of_Tree, Field);
                        Selected : constant Positive :=
                          Positive
                            (Landin.Checking.Field_Index
                               (Types.all, Of_Tree, Value));
                     begin
                        Payload_Count := Payload_Count
                          + IR.Variant_Case_Field_Count
                              (Unit.all,
                               IR.Nth_Field_Shape
                                 (Unit.all, Item, Which),
                               Selected);

                        --  D82's finite and hybrid payload images append
                        --  their prefix folds to the same item-owned image
                        --  run as D67's top-level array fields.  Count them
                        --  before opening that single run below.
                        if Is_Case_Construction (Of_Tree, Value) then
                           for Payload_Position in
                             1 .. Construction_Field_Count (Of_Tree, Value)
                           loop
                              declare
                                 Label : constant Syn.Node_Id :=
                                   Nth_Construction_Field
                                     (Of_Tree, Value, Payload_Position);
                                 Payload : constant Positive := Positive
                                   (Landin.Checking.Field_Index
                                      (Types.all, Of_Tree, Label));
                                 Leaf : constant IR.Field_Shape :=
                                   IR.Nth_Variant_Case_Field
                                     (Unit.all,
                                      IR.Nth_Field_Shape
                                        (Unit.all, Item, Which),
                                      Selected, Payload);
                                 Given : constant Syn.Node_Id :=
                                   Construction_Field_Value
                                     (Of_Tree, Label);
                              begin
                                 if Leaf.Kind = IR.Array_Field_Shape
                                   and then Syn.Kind (Of_Tree, Given)
                                     in Syn.Array_Literal
                                        | Syn.Mixed_Array_Repetition
                                 then
                                    Element_Count := Element_Count
                                      + Syn.Element_Count
                                          (Of_Tree, Given);
                                 elsif Leaf.Kind = IR.Array_Field_Shape
                                   and then Syn.Kind (Of_Tree, Given)
                                     = Syn.Name_Reference
                                 then
                                    declare
                                       Source_Id : constant
                                         Res.Declaration_Id :=
                                           Res.Bound_To
                                             (Meanings.all, Of_Tree, Given);
                                    begin
                                       Resolve_Image (Source_Id);
                                       if Made (Source_Id) then
                                          Element_Count := Element_Count
                                            + Array_Image_Element_Count
                                                (IR.Item_For
                                                   (Unit.all, Source_Id));
                                       end if;
                                    end;
                                 elsif Leaf.Kind = IR.Array_Field_Shape
                                   and then Syn.Kind (Of_Tree, Given)
                                     = Syn.Member_Selection
                                 then
                                    declare
                                       From : constant Syn.Node_Id :=
                                         Syn.Target_Of (Of_Tree, Given);
                                       Source_Id : constant
                                         Res.Declaration_Id :=
                                           Res.Bound_To
                                             (Meanings.all, Of_Tree, From);
                                    begin
                                       Resolve_Image (Source_Id);
                                       if Made (Source_Id) then
                                          Element_Count := Element_Count
                                            + IR.Field_Image_Of
                                                (Unit.all,
                                                 IR.Item_For
                                                   (Unit.all, Source_Id),
                                                 Positive
                                                   (Landin.Checking
                                                      .Field_Index
                                                      (Types.all, Of_Tree,
                                                       Given))).Count;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end loop;
                        end if;
                     end;
                  elsif Syn.Kind
                       (Of_Tree, Construction_Field_Value (Of_Tree, Field))
                       in Syn.Array_Literal | Syn.Mixed_Array_Repetition
                  then
                     Element_Count := Element_Count
                       + Syn.Element_Count
                           (Of_Tree, Construction_Field_Value
                              (Of_Tree, Field));
                  elsif Syn.Kind
                    (Of_Tree, Construction_Field_Value (Of_Tree, Field))
                      = Syn.Name_Reference
                    and then IR.Nth_Field_Shape
                      (Unit.all, Item, Which).Kind
                        = IR.Array_Field_Shape
                  then
                     declare
                        Value : constant Syn.Node_Id :=
                          Construction_Field_Value (Of_Tree, Field);
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Value);
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id) then
                           declare
                              Source_Item : constant IR.Item_Id :=
                                IR.Item_For (Unit.all, Source_Id);
                           begin
                              Element_Count := Element_Count
                                + (if IR.Is_Repeated_Image
                                       (Unit.all, Source_Item)
                                   then Natural
                                     (IR.Image_Prefix_Length
                                        (Unit.all, Source_Item))
                                   else Natural
                                     (IR.Image_Length
                                        (Unit.all, Source_Item)));
                           end;
                        end if;
                     end;
                  elsif Syn.Kind
                    (Of_Tree, Construction_Field_Value (Of_Tree, Field))
                      = Syn.Member_Selection
                    and then IR.Nth_Field_Shape
                      (Unit.all, Item, Which).Kind
                        = IR.Array_Field_Shape
                  then
                     declare
                        Value : constant Syn.Node_Id :=
                          Construction_Field_Value (Of_Tree, Field);
                        From : constant Syn.Node_Id :=
                          Syn.Target_Of (Of_Tree, Value);
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, From);
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id) then
                           declare
                              Source_Item : constant IR.Item_Id :=
                                IR.Item_For (Unit.all, Source_Id);
                              Source_Field : constant Positive :=
                                Positive
                                  (Landin.Checking.Field_Index
                                     (Types.all, Of_Tree, Value));
                           begin
                              Element_Count := Element_Count
                                + IR.Field_Image_Of
                                    (Unit.all, Source_Item,
                                     Source_Field).Count;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;

            declare
               Values : Ty.Folded_Array (1 .. Count) := [others => 0];
               Images : IR.Aggregate_Field_Image_Array (1 .. Count) :=
                 [others => (others => <>)];
               Payloads : IR.Aggregate_Field_Image_Array
                 (1 .. Payload_Count) := [others => (others => <>)];
               Elements : Ty.Folded_Array (1 .. Element_Count) :=
                 [others => 0];
               Cursor : Natural := 0;
               Payload_Cursor : Natural := 0;
            begin
               for Which in 1 .. Count loop
                  Images (Which).Offset := Cursor;

                  if Nodes (Which) /= Syn.No_Node then
                     declare
                        Value : constant Syn.Node_Id :=
                          Construction_Field_Value
                            (Of_Tree, Nodes (Which));
                        Shape : constant IR.Field_Shape :=
                          IR.Nth_Field_Shape (Unit.all, Item, Which);
                     begin
                        if Shape.Kind = IR.Scalar_Field_Shape then
                           if Shape.Signature /= IR.No_Signature then
                              Images (Which).Target :=
                                Static_Field_Target (Of_Tree, Value);
                           else
                              declare
                                 Held  : Ty.Folded;
                                 Known : Boolean;
                              begin
                                 Fold_Constant
                                   (Of_Tree, Value, Held, Known);
                                 if not Known then
                                    raise Landin.Compiler_Defect with
                                      "a module struct literal field the"
                                      & " checker accepted did not fold at"
                                      & " lowering";
                                 end if;
                                 Values (Which) := Held;
                              end;
                           end if;
                        elsif Shape.Kind = IR.Variant_Field_Shape then
                           declare
                              Selected : constant Positive :=
                                Positive
                                  (Landin.Checking.Field_Index
                                     (Types.all, Of_Tree, Value));
                              Payload_Count : constant Natural :=
                                IR.Variant_Case_Field_Count
                                  (Unit.all, Shape, Selected);
                              Payload_Nodes : Node_Array
                                (1 .. Payload_Count) :=
                                  [others => Syn.No_Node];
                           begin
                              Images (Which) :=
                                (Form   => IR.Selected,
                                 Offset => Payload_Cursor,
                                 Count  => Payload_Count,
                                 Value  => Ty.Folded (Selected),
                                 others => <>);

                              if Is_Case_Construction (Of_Tree, Value) then
                                 for Position in
                                   1 .. Construction_Field_Count
                                          (Of_Tree, Value)
                                 loop
                                    declare
                                       Label : constant Syn.Node_Id :=
                                         Nth_Construction_Field
                                           (Of_Tree, Value, Position);
                                       Payload : constant Positive :=
                                         Positive
                                           (Landin.Checking.Field_Index
                                              (Types.all, Of_Tree, Label));
                                    begin
                                       Payload_Nodes (Payload) := Label;
                                    end;
                                 end loop;
                              end if;

                              for Payload in 1 .. Payload_Count loop
                                 declare
                                    Image : IR.Aggregate_Field_Image
                                      renames Payloads
                                        (Payload_Cursor + Payload);
                                    Leaf : constant IR.Field_Shape :=
                                      IR.Nth_Variant_Case_Field
                                        (Unit.all, Shape, Selected, Payload);
                                 begin
                                    Image.Offset := Cursor;
                                    if Leaf.Kind =
                                         IR.Scalar_Field_Shape
                                      and then Payload_Nodes (Payload)
                                        /= Syn.No_Node
                                    then
                                       declare
                                          Given : constant Syn.Node_Id :=
                                            Construction_Field_Value
                                              (Of_Tree,
                                               Payload_Nodes (Payload));
                                       begin
                                          if Leaf.Signature /=
                                               IR.No_Signature
                                          then
                                             Image.Target :=
                                               Static_Field_Target
                                                 (Of_Tree, Given);
                                          else
                                             declare
                                                Held : Ty.Folded;
                                                Known : Boolean;
                                             begin
                                                Fold_Constant
                                                  (Of_Tree, Given,
                                                   Held, Known);
                                                if not Known then
                                                   raise
                                                     Landin.Compiler_Defect
                                                     with "a module variant"
                                                     & " payload the checker"
                                                     & " accepted did not"
                                                     & " fold";
                                                end if;
                                                Image.Value := Held;
                                             end;
                                          end if;
                                       end;
                                    elsif Leaf.Kind = IR.Array_Field_Shape
                                      and then Payload_Nodes (Payload)
                                        /= Syn.No_Node
                                    then
                                       declare
                                          Given : constant Syn.Node_Id :=
                                            Construction_Field_Value
                                              (Of_Tree,
                                               Payload_Nodes (Payload));
                                       begin
                                          if Syn.Kind (Of_Tree, Given)
                                            in Syn.Array_Literal
                                               | Syn.Mixed_Array_Repetition
                                          then
                                             Image.Form :=
                                               (if Syn.Kind (Of_Tree, Given)
                                                    = Syn.Array_Literal
                                                then IR.Finite
                                                else IR.Hybrid);
                                             Image.Count :=
                                               Syn.Element_Count
                                                 (Of_Tree, Given);
                                             for Position in
                                               1 .. Image.Count
                                             loop
                                                declare
                                                   Held : Ty.Folded;
                                                   Known : Boolean;
                                                begin
                                                   Fold_Constant
                                                     (Of_Tree,
                                                      Syn.Nth_Element
                                                        (Of_Tree, Given,
                                                         Position),
                                                      Held, Known);
                                                   if not Known then
                                                      raise
                                                        Landin.Compiler_Defect
                                                        with "a module"
                                                        & " variant array"
                                                        & " payload element"
                                                        & " did not fold";
                                                   end if;
                                                   Elements
                                                     (Cursor + Position) :=
                                                       Held;
                                                end;
                                             end loop;
                                             Cursor := Cursor + Image.Count;

                                             if Image.Form = IR.Hybrid then
                                                declare
                                                   Held : Ty.Folded;
                                                   Known : Boolean;
                                                begin
                                                   Fold_Constant
                                                     (Of_Tree,
                                                      Syn.Repeated_Element
                                                        (Of_Tree, Given),
                                                      Held, Known);
                                                   if not Known then
                                                      raise
                                                        Landin.Compiler_Defect
                                                        with "a module"
                                                        & " variant hybrid"
                                                        & " payload suffix"
                                                        & " did not fold";
                                                   end if;
                                                   Image.Value := Held;
                                                end;
                                             end if;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  = Syn.Array_Repetition
                                          then
                                             declare
                                                Held : Ty.Folded;
                                                Known : Boolean;
                                             begin
                                                Fold_Constant
                                                  (Of_Tree,
                                                   Syn.Repeated_Element
                                                     (Of_Tree, Given),
                                                   Held, Known);
                                                if not Known then
                                                   raise
                                                     Landin.Compiler_Defect
                                                     with "a module variant"
                                                     & " array payload"
                                                     & " pattern did not"
                                                     & " fold";
                                                end if;

                                                --  D34 parity: a full zero
                                                --  pattern is the absent
                                                --  payload image.  D38 keeps
                                                --  a zero hybrid suffix
                                                --  written above.
                                                if Held /= 0 then
                                                   Image.Form := IR.Repeated;
                                                   Image.Value := Held;
                                                end if;
                                             end;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  = Syn.Name_Reference
                                          then
                                             declare
                                                Source_Id : constant
                                                  Res.Declaration_Id :=
                                                    Res.Bound_To
                                                      (Meanings.all,
                                                       Of_Tree, Given);
                                             begin
                                                Resolve_Image (Source_Id);
                                                if Made (Source_Id) then
                                                   Copy_Array_Descriptor
                                                     (IR.Item_For
                                                        (Unit.all,
                                                         Source_Id),
                                                      Cursor, Image,
                                                      Elements);
                                                end if;
                                             end;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  = Syn.Member_Selection
                                          then
                                             declare
                                                From : constant Syn.Node_Id :=
                                                  Syn.Target_Of
                                                    (Of_Tree, Given);
                                                Source_Id : constant
                                                  Res.Declaration_Id :=
                                                    Res.Bound_To
                                                      (Meanings.all,
                                                       Of_Tree, From);
                                             begin
                                                Resolve_Image (Source_Id);
                                                if Made (Source_Id) then
                                                   Copy_Field_Descriptor
                                                     (IR.Item_For
                                                        (Unit.all,
                                                         Source_Id),
                                                      Positive
                                                        (Landin.Checking
                                                           .Field_Index
                                                           (Types.all,
                                                            Of_Tree,
                                                            Given)),
                                                      Cursor, Image,
                                                      Elements);
                                                end if;
                                             end;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  /= Syn.Zeroed_Literal
                                          then
                                             raise Landin.Compiler_Defect
                                               with "a module variant array"
                                               & " payload outside D83"
                                               & " reached lowering";
                                          end if;
                                       end;
                                    elsif Leaf.Kind =
                                      IR.Variant_Field_Shape
                                    then
                                       raise Landin.Compiler_Defect with
                                         "a nested variant payload reached"
                                         & " module image lowering";
                                    end if;
                                 end;
                              end loop;
                              Payload_Cursor := Payload_Cursor
                                + Payload_Count;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                in Syn.Array_Literal
                                   | Syn.Mixed_Array_Repetition
                        then
                           Images (Which).Form :=
                             (if Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Literal
                              then IR.Finite
                              else IR.Hybrid);
                           Images (Which).Count :=
                             Syn.Element_Count (Of_Tree, Value);
                           for Position in
                             1 .. Syn.Element_Count (Of_Tree, Value)
                           loop
                              declare
                                 Held  : Ty.Folded;
                                 Known : Boolean;
                              begin
                                 Fold_Constant
                                   (Of_Tree,
                                    Syn.Nth_Element
                                      (Of_Tree, Value, Position),
                                    Held, Known);
                                 if not Known then
                                    raise Landin.Compiler_Defect with
                                      "a module struct array-field element"
                                      & " the checker accepted did not"
                                      & " fold at lowering";
                                 end if;
                                 Elements (Cursor + Position) := Held;
                              end;
                           end loop;
                           Cursor := Cursor + Images (Which).Count;
                           if Images (Which).Form = IR.Hybrid then
                              declare
                                 Held  : Ty.Folded;
                                 Known : Boolean;
                              begin
                                 Fold_Constant
                                   (Of_Tree,
                                    Syn.Repeated_Element (Of_Tree, Value),
                                    Held, Known);
                                 if not Known then
                                    raise Landin.Compiler_Defect with
                                      "a module struct hybrid suffix the"
                                      & " checker accepted did not fold at"
                                      & " lowering";
                                 end if;
                                 Images (Which).Value := Held;
                              end;
                           end if;
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Array_Repetition
                        then
                           declare
                              Held  : Ty.Folded;
                              Known : Boolean;
                           begin
                              Fold_Constant
                                (Of_Tree,
                                 Syn.Repeated_Element (Of_Tree, Value),
                                 Held, Known);
                              if not Known then
                                 raise Landin.Compiler_Defect with
                                   "a module struct repetition pattern the"
                                   & " checker accepted did not fold at"
                                   & " lowering";
                              end if;

                              --  D34's full zero pattern is the absent
                              --  field image.  A mixed zero suffix remains
                              --  present above because its prefix is written.
                              if Held /= 0 then
                                 Images (Which).Form := IR.Repeated;
                                 Images (Which).Value := Held;
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Name_Reference
                        then
                           declare
                              Source_Id : constant Res.Declaration_Id :=
                                Res.Bound_To
                                  (Meanings.all, Of_Tree, Value);
                           begin
                              Resolve_Image (Source_Id);
                              if Made (Source_Id) then
                                 Copy_Array_Descriptor
                                   (IR.Item_For (Unit.all, Source_Id),
                                    Cursor, Images (Which), Elements);
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Member_Selection
                        then
                           declare
                              From : constant Syn.Node_Id :=
                                Syn.Target_Of (Of_Tree, Value);
                              Source_Id : constant Res.Declaration_Id :=
                                Res.Bound_To
                                  (Meanings.all, Of_Tree, From);
                           begin
                              Resolve_Image (Source_Id);
                              if Made (Source_Id) then
                                 Copy_Field_Descriptor
                                   (IR.Item_For (Unit.all, Source_Id),
                                    Positive
                                      (Landin.Checking.Field_Index
                                         (Types.all, Of_Tree, Value)),
                                    Cursor, Images (Which), Elements);
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                /= Syn.Zeroed_Literal
                        then
                           raise Landin.Compiler_Defect with
                             "a module struct array-field image outside"
                             & " D69/D71 reached lowering";
                        end if;
                     end;
                  end if;
               end loop;

               IR.Set_Aggregate_Image
                 (Unit.all, Item, Values, Images, Payloads, Elements);
               Made (Id) := True;
            end;
         end Set_Image_From_Struct_Literal;

         procedure Set_Image_From_Struct_Field
           (Id        : Res.Declaration_Id;
            Of_Tree   : Syn.Tree;
            Selection : Syn.Node_Id);

         procedure Set_Image_From_Struct_Field
           (Id        : Res.Declaration_Id;
            Of_Tree   : Syn.Tree;
            Selection : Syn.Node_Id)
         is
            From : constant Syn.Node_Id :=
              Syn.Target_Of (Of_Tree, Selection);
            Source_Id : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, From);
            Field : constant Positive :=
              Positive
                (Landin.Checking.Field_Index
                   (Types.all, Of_Tree, Selection));
         begin
            --  D70 resolves the containing aggregate first.  An absent
            --  aggregate image is the complete zero image, so its field and
            --  the destination array both remain absent loader-zeroed data.
            Resolve_Image (Source_Id);
            if not Made (Source_Id) then
               return;
            end if;

            declare
               Source_Item : constant IR.Item_Id :=
                 IR.Item_For (Unit.all, Source_Id);
               Image : constant IR.Aggregate_Field_Image :=
                 IR.Field_Image_Of (Unit.all, Source_Item, Field);
               Destination : constant IR.Item_Id :=
                 IR.Item_For (Unit.all, Id);
            begin
               case Image.Form is
                  when IR.Absent =>
                     null;

                  when IR.Finite =>
                     if Image.Count = 0 then
                        return;
                     end if;

                     declare
                        Values : Ty.Folded_Array (1 .. Image.Count) :=
                          [others => 0];
                     begin
                        for Position in Values'Range loop
                           Values (Position) :=
                             IR.Nth_Field_Element
                               (Unit.all, Source_Item, Field,
                                IR.Part_Position (Position));
                        end loop;
                        IR.Set_Array_Image
                          (Unit.all, Destination, Values);
                     end;
                     Made (Id) := True;

                  when IR.Repeated =>
                     IR.Set_Repeated_Array_Image
                       (Unit.all, Destination, Image.Value);
                     Made (Id) := True;

                  when IR.Hybrid =>
                     declare
                        Prefix : Ty.Folded_Array (1 .. Image.Count) :=
                          [others => 0];
                     begin
                        for Position in Prefix'Range loop
                           Prefix (Position) :=
                             IR.Nth_Field_Element
                               (Unit.all, Source_Item, Field,
                                IR.Part_Position (Position));
                        end loop;
                        IR.Set_Hybrid_Array_Image
                          (Unit.all, Destination, Prefix, Image.Value);
                     end;
                     Made (Id) := True;

                  when IR.Selected | IR.Nested =>
                     raise Landin.Compiler_Defect with
                       "a non-array field was used as an array image";
               end case;
            end;
         end Set_Image_From_Struct_Field;

         procedure Copy_Image_From
           (Destination : Res.Declaration_Id;
            Source_Id   : Res.Declaration_Id);

         procedure Copy_Image_From
           (Destination : Res.Declaration_Id;
            Source_Id   : Res.Declaration_Id)
         is
            Source_Item : constant IR.Item_Id :=
              IR.Item_For (Unit.all, Source_Id);
            Length : constant IR.Element_Total :=
              IR.Image_Length (Unit.all, Source_Item);
         begin
            if IR.Result_Of (Unit.all, Source_Item) = Ty.Aggregate then
               declare
                  Recursive : Boolean := False;
               begin
                  for Position in
                    1 .. IR.Aggregate_Field_Image_Count
                           (Unit.all, Source_Item)
                  loop
                     Recursive := Recursive
                       or else IR.Nth_Image_Descriptor
                         (Unit.all, Source_Item, Position).Form = IR.Nested;
                  end loop;

                  if Recursive then
                     declare
                        Fields : constant Natural :=
                          IR.Field_Count (Unit.all, Source_Item);
                        Descriptor_Count : constant Natural :=
                          IR.Aggregate_Field_Image_Count
                            (Unit.all, Source_Item);
                        Child_Count : constant Natural :=
                          Descriptor_Count - Fields;
                        Element_Count : constant Natural := Natural
                          (Length - IR.Element_Total (Fields));
                        Values : Ty.Folded_Array (1 .. Fields) :=
                          [others => 0];
                        Images : IR.Aggregate_Field_Image_Array
                          (1 .. Fields) := [others => (others => <>)];
                        Children : IR.Aggregate_Field_Image_Array
                          (1 .. Child_Count) := [others => (others => <>)];
                        Elements : Ty.Folded_Array
                          (1 .. Element_Count) := [others => 0];
                     begin
                        for Field in Values'Range loop
                           Values (Field) := IR.Nth_Field_Image
                             (Unit.all, Source_Item, Field);
                           Images (Field) := IR.Nth_Image_Descriptor
                             (Unit.all, Source_Item, Field);
                        end loop;
                        for Child in Children'Range loop
                           Children (Child) := IR.Nth_Image_Descriptor
                             (Unit.all, Source_Item, Fields + Child);
                        end loop;
                        for Element in Elements'Range loop
                           Elements (Element) :=
                             IR.Nth_Aggregate_Image_Element
                               (Unit.all, Source_Item,
                                IR.Part_Position (Element));
                        end loop;
                        IR.Set_Aggregate_Image
                          (Unit.all,
                           IR.Item_For (Unit.all, Destination), Values,
                           Images, Children, Elements);
                        Made (Destination) := True;
                     end;
                     return;
                  end if;
               end;

               declare
                  Fields : constant Natural :=
                    IR.Field_Count (Unit.all, Source_Item);
                  Elements_Count : constant Natural :=
                    Natural (Length - IR.Element_Total (Fields));
                  Payload_Count : constant Natural :=
                    IR.Aggregate_Field_Image_Count
                      (Unit.all, Source_Item) - Fields;
                  Values : Ty.Folded_Array (1 .. Fields) := [others => 0];
                  Images : IR.Aggregate_Field_Image_Array
                    (1 .. Fields) := [others => (others => <>)];
                  Payloads : IR.Aggregate_Field_Image_Array
                    (1 .. Payload_Count) := [others => (others => <>)];
                  Elements : Ty.Folded_Array (1 .. Elements_Count) :=
                    [others => 0];
                  Cursor : Natural := 0;
                  Payload_Cursor : Natural := 0;
               begin
                  for Field in 1 .. Fields loop
                     Values (Field) :=
                       IR.Nth_Field_Image (Unit.all, Source_Item, Field);
                     declare
                        Source_Image : constant IR.Aggregate_Field_Image :=
                          IR.Field_Image_Of
                            (Unit.all, Source_Item, Field);
                     begin
                        if Source_Image.Form = IR.Selected then
                           Images (Field) := Source_Image;
                           Images (Field).Offset := Payload_Cursor;
                           for Payload in 1 .. Source_Image.Count loop
                              declare
                                 Source_Payload : constant
                                   IR.Aggregate_Field_Image :=
                                     IR.Variant_Payload_Image_Of
                                       (Unit.all, Source_Item, Field,
                                        Payload);
                                 Target : IR.Aggregate_Field_Image renames
                                   Payloads (Payload_Cursor + Payload);
                              begin
                                 Target := Source_Payload;
                                 Target.Offset := Cursor;
                                 if Source_Payload.Form
                                      in IR.Finite | IR.Hybrid
                                 then
                                    for Position in
                                      1 .. Source_Payload.Count
                                    loop
                                       Elements (Cursor + Position) :=
                                         IR.Nth_Variant_Field_Element
                                           (Unit.all, Source_Item, Field,
                                            Payload,
                                            IR.Part_Position (Position));
                                    end loop;
                                 elsif Source_Payload.Form = IR.Selected
                                 then
                                    raise Landin.Compiler_Defect with
                                      "a nested selected variant image"
                                      & " reached aggregate image copying";
                                 elsif Source_Payload.Count /= 0 then
                                    raise Landin.Compiler_Defect with
                                      "a compact variant payload image"
                                      & " carried finite elements";
                                 end if;
                                 Cursor := Cursor + Source_Payload.Count;
                              end;
                           end loop;
                           Payload_Cursor := Payload_Cursor
                             + Source_Image.Count;
                        else
                           Copy_Field_Descriptor
                             (Source_Item, Field, Cursor, Images (Field),
                              Elements);
                        end if;
                     end;
                  end loop;
                  IR.Set_Aggregate_Image
                    (Unit.all, IR.Item_For (Unit.all, Destination), Values,
                     Images, Payloads, Elements);
                  Made (Destination) := True;
               end;
               return;
            end if;

            if IR.Is_Repeated_Image (Unit.all, Source_Item) then
               declare
                  Prefix : constant IR.Element_Total :=
                    IR.Image_Prefix_Length (Unit.all, Source_Item);
               begin
                  if Prefix = 0 then
                     IR.Set_Repeated_Array_Image
                       (Unit.all, IR.Item_For (Unit.all, Destination),
                        IR.Repeated_Image_Value (Unit.all, Source_Item));
                  else
                     declare
                        Values : Ty.Folded_Array
                          (1 .. Positive (Prefix)) := [others => 0];
                     begin
                        for Position in Values'Range loop
                           Values (Position) :=
                             IR.Nth_Image
                               (Unit.all, Source_Item,
                                IR.Part_Position (Position));
                        end loop;
                        IR.Set_Hybrid_Array_Image
                          (Unit.all, IR.Item_For (Unit.all, Destination),
                           Values,
                           IR.Repeated_Image_Value (Unit.all, Source_Item));
                     end;
                  end if;
               end;
               Made (Destination) := True;
               return;
            end if;

            if Length = 0 then
               return;
            end if;

            declare
               Values : Ty.Folded_Array
                 (1 .. Positive (Length)) := [others => 0];
            begin
               for Position in Values'Range loop
                  Values (Position) :=
                    IR.Nth_Image
                      (Unit.all, Source_Item,
                       IR.Part_Position (Position));
               end loop;

               IR.Set_Array_Image
                 (Unit.all,
                  IR.Item_For (Unit.all, Destination), Values);
               Made (Destination) := True;
            end;
         end Copy_Image_From;

         procedure Resolve_Image (Id : Res.Declaration_Id)
         is
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
            Value : constant Syn.Node_Id :=
              Syn.Value_Of (Their_Tree.all, Node);
         begin
            case Where (Id) is
               when Resolved =>
                  return;
               when Visiting =>
                  --  A cycle the checker already reported: leave the
                  --  destination without an image.  Following it would
                  --  loop; the diagnostic is the reader's answer here.
                  return;
               when Unseen =>
                  null;
            end case;

            Where (Id) := Visiting;

            if Value = Syn.No_Node then
               null;
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Zeroed_Literal then
               --  D27's explicit zero image remains absent, just like D10's
               --  omitted initializer; the backend therefore selects .bss.
               null;
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Array_Literal then
               Set_Image_From_Literal (Id, Their_Tree.all, Value);
            elsif Is_Struct_Construction (Their_Tree.all, Value) then
               Set_Image_From_Struct_Literal (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Array_Repetition then
               Set_Image_From_Repetition (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value)
                    = Syn.Mixed_Array_Repetition
            then
               Set_Image_From_Mixed_Repetition (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Member_Selection
            then
               Set_Image_From_Struct_Field (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Name_Reference
              and then Res.Verdict_Of
                         (Meanings.all, Their_Tree.all, Value) = Res.Bound
            then
               declare
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To
                      (Meanings.all, Their_Tree.all, Value);
               begin
                  if Res.Sort_Of (Meanings.all, Source_Id)
                       = Res.Module_Binding
                    and then Landin.Checking.Type_Of
                               (Types.all, Source_Id)
                               = Landin.Checking.Type_Of (Types.all, Id)
                    and then
                      (Landin.Checking.Type_Of (Types.all, Id)
                         = Ty.Fixed_Array
                       or else
                         (Landin.Checking.Type_Of (Types.all, Id)
                            = Ty.Aggregate
                          and then Landin.Checking.Nominal_Of
                            (Types.all, Source_Id)
                            = Landin.Checking.Nominal_Of (Types.all, Id)))
                  then
                     Resolve_Image (Source_Id);
                     if Made (Source_Id) then
                        Copy_Image_From (Id, Source_Id);
                     end if;
                  end if;
               end;
            end if;

            Where (Id) := Resolved;
         end Resolve_Image;
      begin
         if Declarations > 0 then
            for Id in Res.Declaration_Id'(1) ..
                      Res.Declaration_Id (Declarations)
            loop
               if Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding
                 and then Landin.Checking.Type_Of (Types.all, Id)
                          in Ty.Fixed_Array | Ty.Aggregate
               then
                  Resolve_Image (Id);
               end if;
            end loop;
         end if;
      end Resolve_Module_Images;

      --  Every Unit this stage builds, in every build mode.  A failure
      --  is a Landin.Compiler_Defect and never a diagnostic: the
      --  frontend refused every ill-formed program and this stage
      --  refused to run on a refused one, so nothing a program can say
      --  reaches here.  Facts flow in so D24's per-position image values
      --  are held to fitting their element type at this compilation's
      --  target rather than at the host running the compiler.
      Landin.IR.Verifier.Verify (Unit.all, Facts);

      Outcome := Continue;
   end Run;

end Landin.Stages.Lowering;
