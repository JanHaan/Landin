with Landin.Stages.Folding;
with Ada.Containers.Indefinite_Ordered_Maps;
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
with Landin.Tokens;
with Landin.Tokens.Text;
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
   use type IR.Opcode;
   use type IR.Element_Total;
   use type IR.Field_Image_Form;
   use type IR.Field_Shape_Kind;
   use type IR.Atom_Set_Id;
   use type IR.Evidence_Id;
   use type IR.Item_Id;
   use type IR.Item_Kind;
   use type IR.Nominal_Type_Id;
   use type IR.Slot_Id;
   use type IR.Signature_Id;
   use all type IR.Storage_Kind;
   use type IR.Part_Position;
   use type IR.Path_Step;
   use type IR.Path_Step_Array;
   use type IR.Value_Id;
   use type Landin.Checking.Array_Element_Form;
   use type Landin.Checking.Actual_Kind;
   use type Landin.Checking.Atom_Set_Id;
   use type Landin.Checking.Constraint_Id;
   use type Landin.Checking.Concept_Id;
   use type Landin.Checking.Conformance_Id;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Error_Set_Form;
   use type Landin.Checking.Field_Kind;
   use type Landin.Checking.Nominal_Type_Id;
   use type Landin.Checking.Routine_Instance_Id;
   use type Landin.Checking.Routine_Instance_State;
   use type Landin.Checking.Signature_Id;
   use type Landin.Checking.Text_Conversion_Kind;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Tokens.Assignment_Operator;
   use type Res.Application_Class;
   use type Res.Argument_Role;
   use type Res.Call_Match_State;
   use type Res.Declaration_Id;
   use type Res.Declaration_Sort;
   use type Res.Verdict;
   use type Ty.Folded;
   use type Ty.Magnitude;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Syn.Parameter_Convention;
   use type Landin.Checking.Reference_Id;
   use type Ty.Type_Kind;
   use type Ty.Reference_View;

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
      Spellings : constant not null access Landin.Source.Names.Table :=
        Landin.Stages.Identities (Context);
      Types : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);
      Unit : constant not null access IR.Unit :=
        Landin.Stages.Code (Context);
      Facts : constant Landin.Targets.Target_Facts :=
        Landin.Stages.Target (Context);
      Activity : constant not null access Landin.Configuration.Table :=
        Configurations (Context);

      --  Scalar module expressions containing an opaque representation
      --  conversion are folded with the shared guarded image folder before
      --  the datum block is emitted. They never create runtime frame storage.
      subtype Module_Image_Index is Res.Declaration_Id range
        1 .. Res.Declaration_Id
          (Natural'Max (1, Res.Declaration_Count (Meanings.all)));
      Distinct_Image : array (Module_Image_Index) of Ty.Folded :=
        [others => 0];
      Has_Distinct_Image : array (Module_Image_Index) of Boolean :=
        [others => False];

      function Has_Distinct_Conversion
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Has_Distinct_Conversion
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean is
      begin
         if Node = Syn.No_Node then
            return False;
         elsif Landin.Checking.Distinct_Conversion_Of
           (Types.all, Of_Tree, Node) /= Landin.Checking.No_Nominal_Type
         then
            return True;
         end if;
         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            if Has_Distinct_Conversion
              (Of_Tree, Syn.Slot (Of_Tree, Node, Position))
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Distinct_Conversion;

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

      subtype Source_Evidence is Positive range
        1 .. Positive'Max
               (1, Landin.Checking.Conformance_Count (Types.all));
      type Evidence_Map is array (Source_Evidence) of IR.Evidence_Id;
      type Evidence_Slot_Map is array (Source_Evidence) of IR.Slot_Id;
      Evidence : Evidence_Map := [others => IR.No_Evidence];
      Any_Evidence : Evidence_Map := [others => IR.No_Evidence];
      Evidence_Slots : Evidence_Slot_Map := [others => IR.No_Slot];

      subtype Source_Routine_Instance is Positive range
        1 .. Positive'Max
               (1, Landin.Checking.Routine_Instance_Count (Types.all));
      type Generic_Signature_Map is
        array (Source_Routine_Instance) of IR.Signature_Id;
      Generic_Signatures : Generic_Signature_Map :=
        [others => IR.No_Signature];

      --  A constrained provider has hidden evidence parameters. Its table
      --  entry binds those parameters and retains the concept's written ABI.
      type Provider_Item_Map is
        array (Source_Routine_Instance) of IR.Item_Id;
      Provider_Items : Provider_Item_Map := [others => IR.No_Item];
      type Bound_Provider is record
         Source : Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.No_Routine_Instance;
         Item   : IR.Item_Id := IR.No_Item;
         Target : IR.Item_Id := IR.No_Item;
      end record;
      type Bound_Provider_Array is
        array (Source_Routine_Instance) of Bound_Provider;
      Bound_Providers : Bound_Provider_Array;
      Bound_Provider_Count : Natural := 0;

      function Evidence_For
        (Source : Landin.Checking.Conformance_Id) return IR.Evidence_Id;

      function Evidence_For
        (Source : Landin.Checking.Conformance_Id) return IR.Evidence_Id
      is
         Position : constant Positive :=
           Landin.Checking.Conformance_Identities.Position
             (Types.all, Source);
      begin
         if Evidence (Position) = IR.No_Evidence then
            raise Landin.Compiler_Defect with
              "a checker conformance was not mapped before lowering";
         end if;
         return Evidence (Position);
      end Evidence_For;

      function Any_Evidence_For
        (Source : Landin.Checking.Conformance_Id) return IR.Evidence_Id;

      function Any_Evidence_For
        (Source : Landin.Checking.Conformance_Id) return IR.Evidence_Id
      is
         Position : constant Positive :=
           Landin.Checking.Conformance_Identities.Position
             (Types.all, Source);
      begin
         if Any_Evidence (Position) = IR.No_Evidence then
            raise Landin.Compiler_Defect with
              "an any conformance was not mapped before lowering";
         end if;
         return Any_Evidence (Position);
      end Any_Evidence_For;

      function Neutral_Element
        (Part : Landin.Checking.Signature_Part) return IR.Field_Shape;

      function Pointee_For
        (Reference : Landin.Checking.Reference_Id) return IR.Pointee_Id;

      function Neutral_Result_Part
        (Part : Landin.Checking.Signature_Part) return IR.Field_Shape;

      function Signature_For
        (Source : Landin.Checking.Signature_Id) return IR.Signature_Id;

      function Signature_For_Instance
        (Instance : Landin.Checking.Routine_Instance_Id)
         return IR.Signature_Id;

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

      --  D161/D181: every text literal is one read-only datum holding its
      --  contextual code units and [0260]'s trailing NUL.  The key includes
      --  the element width, so equal UTF-8 and cstring contents share bytes
      --  while UTF-16 remains a separately shaped object.
      package Text_Datum_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => IR.Item_Id, "=" => IR."=");

      Text_Data : Text_Datum_Maps.Map;

      function Text_Units
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
         return Landin.Tokens.Text.Code_Unit_Array;

      function Text_Key
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return String;

      function Text_Element
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Scalar_Name;

      function Character_Magnitude
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Magnitude;

      function Text_Datum
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Item_Id;

      procedure Register_Text_Datum
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      function Text_Units
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
         return Landin.Tokens.Text.Code_Unit_Array
      is
         Snap : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Lexeme : constant String :=
           Landin.Source.Slice (Snap, Syn.Where (Of_Tree, Node));
         Decoded : Landin.Tokens.Text.Code_Unit_Array (1 .. Lexeme'Length);
         Length : Natural;
         Fault : Landin.Tokens.Text.Problem;
         Fault_First, Fault_Last : Natural;
         Descriptor : constant Landin.Checking.Reference_Descriptor :=
           Landin.Checking.Descriptor_Of
             (Types.all,
              Landin.Checking.Reference_Of (Types.all, Of_Tree, Node));
         Encoding : constant Landin.Tokens.Text.Literal_Encoding :=
           (if Descriptor.View = Ty.Ordinary_View
            then Landin.Tokens.Text.Byte_Units
            elsif Descriptor.View = Ty.Utf16_View
            then Landin.Tokens.Text.UTF16_Units
            else Landin.Tokens.Text.UTF8_Units);
      begin
         Landin.Tokens.Text.Decode_View
           (Lexeme, Syn.Kind (Of_Tree, Node) = Syn.Raw_Literal,
            Encoding, Decoded, Length, Fault, Fault_First, Fault_Last);
         if Fault not in Landin.Tokens.Text.Well_Formed then
            raise Landin.Compiler_Defect with
              "a malformed text literal reached lowering";
         end if;
         return Decoded (1 .. Length);
      end Text_Units;

      function Text_Element
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Scalar_Name
      is
         Descriptor : constant Landin.Checking.Reference_Descriptor :=
           Landin.Checking.Descriptor_Of
             (Types.all,
              Landin.Checking.Reference_Of (Types.all, Of_Tree, Node));
      begin
         return
           (if Descriptor.View = Ty.Utf16_View then Ty.U16 else Ty.U8);
      end Text_Element;

      function Text_Key
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return String
      is
         Units : constant Landin.Tokens.Text.Code_Unit_Array :=
           Text_Units (Of_Tree, Node);
         Element : constant Ty.Scalar_Name := Text_Element (Of_Tree, Node);
         Key : String
           (1 .. 1 + Units'Length * (if Element = Ty.U16 then 2 else 1));
         Cursor : Positive := 2;
      begin
         Key (1) := (if Element = Ty.U16 then Character'Val (16) else
                       Character'Val (8));
         for Unit of Units loop
            if Element = Ty.U16 then
               Key (Cursor) := Character'Val (Natural (Unit) / 256);
               Cursor := Cursor + 1;
            end if;
            Key (Cursor) := Character'Val (Natural (Unit) mod 256);
            Cursor := Cursor + 1;
         end loop;
         return Key;
      end Text_Key;

      function Character_Magnitude
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Magnitude
      is
         Snap : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Lexeme : constant String :=
           Landin.Source.Slice (Snap, Syn.Anchor (Of_Tree, Node));
         Value, Fault_First, Fault_Last : Natural;
         Fault : Landin.Tokens.Text.Problem;
      begin
         Landin.Tokens.Text.Decode_Character
           (Lexeme, Value, Fault, Fault_First, Fault_Last);
         if Fault not in Landin.Tokens.Text.Well_Formed then
            raise Landin.Compiler_Defect with
              "a malformed character literal reached lowering";
         end if;
         return Ty.Magnitude (Value);
      end Character_Magnitude;

      function Text_Datum
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Item_Id
      is
         Key : constant String := Text_Key (Of_Tree, Node);
         Found : constant Text_Datum_Maps.Cursor := Text_Data.Find (Key);
      begin
         if Text_Datum_Maps.Has_Element (Found) then
            return Text_Datum_Maps.Element (Found);
         end if;
         raise Landin.Compiler_Defect with
           "a checked text literal has no registered datum";
      end Text_Datum;

      procedure Register_Text_Datum
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Site : constant Landin.Provenance.Origin :=
           Syn.Origin (Of_Tree, Node);
         Key : constant String := Text_Key (Of_Tree, Node);
         Units : constant Landin.Tokens.Text.Code_Unit_Array :=
           Text_Units (Of_Tree, Node);
         Image : Ty.Folded_Array (1 .. Units'Length + 1);
         Made : IR.Item_Id;
      begin
         if Text_Data.Contains (Key) then
            return;
         end if;
         for Index in Units'Range loop
            Image (Index) := Ty.Folded (Units (Index));
         end loop;
         Image (Image'Last) := 0;
         Made := IR.Add_Item
           (Unit.all, IR.Datum, Res.No_Declaration, Ty.Fixed_Array, Site);
         IR.Set_Array
           (Unit.all, Made, Text_Element (Of_Tree, Node),
            IR.Element_Total (Image'Length));
         IR.Set_Array_Image (Unit.all, Made, Image);
         IR.Mark_Read_Only (Unit.all, Made);
         Text_Data.Insert (Key, Made);
      end Register_Text_Datum;

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
         --  D187: [1120]'s region depth where this `defer` or `undo` was
         --  written.  The call is evaluated at an exit, which may be
         --  inside a region the registration is not in, so the depth
         --  travels with the entry the way its scope already does.
         Region : Natural := 0;
      end record;

      package Cleanup_Entries is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Cleanup_Entry);

      package Cleanup_Indexes is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Positive);

      Cleanup_Stack : Cleanup_Entries.Vector;

      package Stored_Path_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => IR.Path_Step);

      type Loop_Entry is record
         Label        : Landin.Source.Names.Name_Id :=
           Landin.Source.Names.No_Name;
         Head         : IR.Block_Id := IR.No_Block;
         Exit_Block   : IR.Block_Id := IR.No_Block;
         Cleanup_Base : Natural := 0;
         Value_Destination : IR.Slot_Id := IR.No_Slot;
         Value_Destination_Field : Natural := 0;
         Value_Destination_Path : Stored_Path_Vectors.Vector;
      end record;

      package Loop_Entries is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Loop_Entry);

      Loop_Stack : Loop_Entries.Vector;

      function Transfer_Loop
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Loop_Entry;

      function Transfer_Loop
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Loop_Entry
      is
         Target : constant Landin.Source.Names.Name_Id :=
           Syn.Name (Of_Tree, Node);
      begin
         for Index in reverse 1 .. Natural (Loop_Stack.Length) loop
            declare
               Candidate : constant Loop_Entry := Loop_Stack (Index);
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

      function Site_Of (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Landin.Provenance.Origin
        is (Syn.Origin (Of_Tree, Node));

      function Type_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Type_Kind
        is (Landin.Checking.Type_Of (Types.all, Of_Tree, Node));

      function Is_Utf8_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Utf8_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Element_Index then
            return False;
         end if;
         declare
            From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
         begin
            return Type_At (Of_Tree, From) = Ty.Slice_Value
              and then Landin.Checking.Descriptor_Of
                (Types.all,
                 Landin.Checking.Reference_Of
                   (Types.all, Of_Tree, From)).View = Ty.Utf8_View;
         end;
      end Is_Utf8_Index;

      function Is_Float_Special
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            and then Syn.Kind
              (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Syn.Type_Name
            and then Type_At (Of_Tree, Node) in Ty.Float_Name
            and then Landin.Source.Names.Spelling
              (Spellings.all, Syn.Name (Of_Tree, Node))
                in "infinity" | "nan");

      function Float_Special_At
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Magnitude
        is (Ty.Float_Special_Bits
              (Ty.Float_Name (Type_At (Of_Tree, Node)),
               (if Landin.Source.Names.Spelling
                     (Spellings.all, Syn.Name (Of_Tree, Node)) = "infinity"
                then Ty.Infinity else Ty.Quiet_NaN)))
        with Pre => Is_Float_Special (Of_Tree, Node);

      function Conversion_Scalar
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;

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
         Sources : IR.Return_Source_Array
           (1 .. Positive'Max (1, Count * Positive'Max (1, Results'Length))) :=
             [others => (others => 1)];
         Source_Count : Natural := 0;

         function Converted
           (Part : Landin.Checking.Signature_Part) return IR.Signature_Part;

         function Converted
           (Part : Landin.Checking.Signature_Part)
            return IR.Signature_Part
         is
            Element : constant IR.Field_Shape :=
              (if Part.Kind = Ty.Fixed_Array
                  and then Part.Convention /= Syn.Inout_Convention
               then Neutral_Element (Part) else (others => <>));
         begin
            return (Element_Shape => Element,
               Pointee =>
                 (if Part.Convention = Syn.Inout_Convention
                  then IR.Add_Pointee
                    (Unit.all, Neutral_Result_Part (Part))
                  elsif Part.Kind = Ty.Pointer_Value
                  then Pointee_For (Part.Reference)
                  else IR.No_Pointee),
               Kind    =>
                 (if Part.Convention = Syn.Inout_Convention then Ty.Usize
                  elsif Part.Kind = Ty.Atom_Value then Ty.U32
                  elsif Part.Kind = Ty.Pointer_Value then Ty.Usize
                  elsif Part.Kind in Ty.Slice_Value | Ty.Any_Value
                  then Ty.Fixed_Array
                  else Part.Kind),
               Nominal =>
                 (if Part.Convention = Syn.Inout_Convention
                    or else Part.Kind in Ty.Slice_Value | Ty.Any_Value
                  then IR.No_Nominal_Type
                  else Nominal_For (Part.Nominal)),
               Length  =>
                 (if Part.Convention = Syn.Inout_Convention then 0
                  elsif Part.Kind in Ty.Slice_Value | Ty.Any_Value then 2
                  else IR.Element_Total (Part.Length)),
               Element =>
                 (if Part.Convention = Syn.Inout_Convention then Ty.Bool
                  elsif Part.Kind in Ty.Slice_Value | Ty.Any_Value
                  then Ty.Usize
                  elsif Part.Kind = Ty.Fixed_Array
                  then Element.Element
                  else Part.Element),
               Signature =>
                 (if Part.Convention /= Syn.Inout_Convention
                    and then Part.Kind = Ty.Function_Value
                  then Signature_For (Part.Signature)
                  else IR.No_Signature),
               Convention =>
                 (case Part.Convention is
                     when Syn.Implicit_In | Syn.Explicit_In => IR.In_Value,
                     when Syn.Inout_Convention => IR.Inout_Place,
                     when Syn.Sink_Convention => IR.Sink_Value),
               Escaping => Part.Escaping,
               Atoms =>
                 (if Part.Convention /= Syn.Inout_Convention
                    and then Part.Kind = Ty.Atom_Value
                  then Atom_Set_For (Part.Atoms)
                  else IR.No_Atom_Set));
         end Converted;
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
            for Position in
              1 .. Landin.Checking.Signature_Return_Source_Count
                (Types.all, Source, Index)
            loop
               Source_Count := Source_Count + 1;
               Sources (Source_Count) :=
                 (Result => Index,
                  Parameter =>
                    Landin.Checking.Nth_Signature_Return_Source
                      (Types.all, Source, Index, Position));
            end loop;
         end loop;
         Signatures (Positive (Source)) :=
           IR.Add_Signature_With_Results
             (Unit.all, Parts, Results,
              Atom_Set_For
                (Landin.Checking.Signature_Errors (Types.all, Source)),
              (if Source_Count = 0 then IR.No_Return_Sources
               else Sources (1 .. Source_Count)),
              C_ABI => Landin.Checking.Signature_Uses_C_ABI
                (Types.all, Source),
              Variadic => Landin.Checking.Signature_Is_Variadic
                (Types.all, Source));
         return Signatures (Positive (Source));
      end Signature_For;

      function Signature_For_Instance
        (Instance : Landin.Checking.Routine_Instance_Id)
         return IR.Signature_Id
      is
         Position : constant Positive :=
           Landin.Checking.Routine_Identities.Position
             (Types.all, Instance);
         Source : constant IR.Signature_Id := Signature_For
           (Landin.Checking.Routine_Signature_Of (Types.all, Instance));
         Hidden : constant Natural :=
           Landin.Checking.Routine_Evidence_Count (Types.all, Instance);
         Parameter_Count : constant Natural :=
           IR.Signature_Parameter_Count (Unit.all, Source);
         Result_Count : constant Natural :=
           IR.Signature_Result_Count (Unit.all, Source);
         Parameters : IR.Signature_Part_Array
           (1 .. Hidden + Parameter_Count) := [others => (others => <>)];
         Results : IR.Signature_Part_Array (1 .. Result_Count) :=
           [others => (others => <>)];
         Sources : IR.Return_Source_Array
           (1 .. Positive'Max (1, Result_Count * Parameter_Count)) :=
             [others => (others => 1)];
         Source_Count : Natural := 0;
      begin
         if Generic_Signatures (Position) /= IR.No_Signature then
            return Generic_Signatures (Position);
         end if;
         for Index in 1 .. Hidden loop
            Parameters (Index) :=
              (Kind => Ty.Usize, Convention => IR.In_Value, others => <>);
         end loop;
         for Index in 1 .. Parameter_Count loop
            Parameters (Hidden + Index) :=
              IR.Nth_Signature_Parameter (Unit.all, Source, Index);
         end loop;
         for Index in 1 .. Result_Count loop
            Results (Index) :=
              IR.Nth_Signature_Result (Unit.all, Source, Index);
            for Which in 1 .. IR.Signature_Return_Source_Count
              (Unit.all, Source, Index)
            loop
               Source_Count := Source_Count + 1;
               Sources (Source_Count) :=
                 (Result => Index,
                  Parameter => Hidden
                    + IR.Nth_Signature_Return_Source
                        (Unit.all, Source, Index, Which));
            end loop;
         end loop;
         Generic_Signatures (Position) :=
           IR.Add_Signature_With_Results
             (Unit.all, Parameters, Results,
              IR.Signature_Errors (Unit.all, Source),
              (if Source_Count = 0 then IR.No_Return_Sources
               else Sources (1 .. Source_Count)),
              C_ABI => IR.Signature_Uses_C_ABI (Unit.all, Source),
              Variadic => IR.Signature_Is_Variadic (Unit.all, Source));
         return Generic_Signatures (Position);
      end Signature_For_Instance;

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

      function Update_Opcode
        (Operation : Landin.Tokens.Assignment_Operator) return IR.Opcode
      is (case Operation is
             when Landin.Tokens.Add_Assignment => IR.Add,
             when Landin.Tokens.Subtract_Assignment => IR.Subtract,
             when Landin.Tokens.Multiply_Assignment => IR.Multiply,
             when Landin.Tokens.Divide_Assignment => IR.Divide,
             when Landin.Tokens.Remainder_Assignment => IR.Remainder,
             when Landin.Tokens.Bitwise_And_Assignment => IR.Bitwise_And,
             when Landin.Tokens.Bitwise_Or_Assignment => IR.Bitwise_Or,
             when Landin.Tokens.Bitwise_Xor_Assignment => IR.Bitwise_Xor,
             when Landin.Tokens.Shift_Left_Assignment => IR.Shift_Left,
             when Landin.Tokens.Shift_Right_Assignment => IR.Shift_Right,
             when Landin.Tokens.Wrapping_Add_Assignment => IR.Wrapping_Add,
             when Landin.Tokens.Wrapping_Subtract_Assignment =>
               IR.Wrapping_Subtract,
             when Landin.Tokens.Wrapping_Multiply_Assignment =>
               IR.Wrapping_Multiply,
             when Landin.Tokens.Plain_Assignment =>
               raise Landin.Compiler_Defect with
                 "plain assignment has no updating opcode");

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

      type Stored_Place is record
         Place : IR.Storage := (others => <>);
         Base  : Natural := 0;
         Steps : Stored_Path_Vectors.Vector;
      end record;

      function Stored_Steps (Place : Stored_Place)
        return IR.Path_Step_Array;

      function Has_Computed_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Has_Reference_Storage
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

      type Slice_Values is record
         Base   : IR.Value_Id := IR.No_Value;
         Length : IR.Value_Id := IR.No_Value;
      end record;

      function Slice_Shape
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape;

      function Load_Slice_Component
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Position : IR.Part_Position) return IR.Value_Id;

      function Lower_Slice
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return Slice_Values;

      procedure Lower_Slice_Into
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Destination : IR.Slot_Id);

      function Lower_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      --  D188: every scalar value passes through Lower_Expression, so
      --  [0660]'s runtime check is emitted at that one exit and nowhere
      --  else.  The checker decided which nodes owe one; this only obeys.
      function Lower_Unconstrained
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      --  D188: a compound assignment and [1900]'s `inc` store the
      --  operator's result rather than any expression the source wrote, so
      --  their check hangs on the statement and is applied here.
      function Checked_Update
        (Of_Tree : Syn.Tree;
         Stmt    : Syn.Node_Id;
         Value   : IR.Value_Id) return IR.Value_Id;

      function Lower_Condition
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
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps;
         Direct_Value : Syn.Node_Id := Syn.No_Node);

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

      --  D189/[0480]: a pointer union's two cases are told apart by the
      --  reserved zero, so the whole form is one comparison against it.
      procedure Lower_Pointer_Union_Match
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

      procedure Lower_Loop
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps);

      procedure Lower_Loop_Transfer
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id);

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

      --  D15/D188: which scalar type a one-argument call applies, whether
      --  it is written with [1790]'s own name, an alias of one, or [0660]'s
      --  range subtype.  Ill_Typed means this is an ordinary call.  The
      --  checker decided the same question the same way.
      function Conversion_Scalar
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Call
           or else Syn.Argument_Count (Of_Tree, Node) /= 1
           or else Syn.Kind
             (Of_Tree, Syn.Callee_Of (Of_Tree, Node))
               not in Syn.Name_Reference | Syn.Member_Selection
         then
            return Ty.Ill_Typed;
         end if;

         declare
            Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Node);
            Named  : constant Ty.Type_Kind :=
              (if Syn.Kind (Of_Tree, Callee) = Syn.Name_Reference
               then Landin.Checking.Named
                 (Types.all, Syn.Name (Of_Tree, Callee))
               else Ty.Ill_Typed);
         begin
            if Named in Ty.Scalar_Name then
               return Named;
            end if;

            if Res.Verdict_Of (Meanings.all, Of_Tree, Callee) = Res.Bound
              and then Res.Sort_Of
                (Meanings.all, Res.Bound_To (Meanings.all, Of_Tree, Callee))
                  = Res.Module_Type
              and then Landin.Checking.Type_Of
                (Types.all,
                 Res.Bound_To (Meanings.all, Of_Tree, Callee))
                  in Ty.Scalar_Name
            then
               return Landin.Checking.Type_Of
                 (Types.all, Res.Bound_To (Meanings.all, Of_Tree, Callee));
            end if;
         end;

         return Ty.Ill_Typed;
      end Conversion_Scalar;

      function Scalar_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Scalar_Name
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
      begin
         if Held in Ty.Function_Value | Ty.Pointer_Value then
            return Ty.Usize;
         elsif Held = Ty.Atom_Value then
            return Ty.U32;
         end if;
         if Held not in Ty.Scalar_Name then
            raise Landin.Compiler_Defect with
              "an expression reached the lowering with no scalar carrier: "
              & Ty.Type_Kind'Image (Held)
              & " at node" & Syn.Node_Id'Image (Node);
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
      --
      --  D187: this is the one emitter whose instructions come from
      --  source written somewhere else, so it emits them in the region
      --  the `defer` or `undo` stands in and not in the one the exit
      --  reaching it stands in.  Without this a `return`, `break` or
      --  `fail` inside `unchecked begin` would quietly take the overflow
      --  edge off a cleanup argument written outside it, and [1120]'s
      --  claim that the word reaches only the code written inside it
      --  would be false where a reader stands.
      procedure Lower_Cleanup_Call
        (Of_Tree : Syn.Tree; Action : Cleanup_Entry)
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Action.Call);
         Reached_From : constant Natural :=
           IR.Unchecked_Depth (Unit.all, Filling);
      begin
         IR.Set_Unchecked_Depth (Unit.all, Filling, Action.Region);
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
         IR.Set_Unchecked_Depth (Unit.all, Filling, Reached_From);
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
        is ((Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
             and then Res.Verdict_Of
               (Meanings.all, Of_Tree, Node) /= Res.Bound)
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

      function Evidence_Shape
        (Actual : Landin.Checking.Actual_Key) return IR.Field_Shape;

      --  One field of D128's anonymous result aggregate.  D131 gives a
      --  nominal aggregate the same one `usize` field plus its signature.

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
                  Atoms =>
                    (if Source.Atoms /= Landin.Checking.No_Atom_Set
                     then Atom_Set_For (Source.Atoms) else IR.No_Atom_Set),
                  others    => <>);

            when Landin.Checking.Reference_Field =>
               declare
                  Descriptor : constant Landin.Checking.Reference_Descriptor :=
                    Landin.Checking.Descriptor_Of
                      (Types.all, Source.Reference);
               begin
                  return
                    (Kind =>
                       (if Descriptor.Kind = Ty.Pointer_Value
                        then IR.Scalar_Field_Shape
                        else IR.Array_Field_Shape),
                     Element => Ty.Usize,
                     Pointee =>
                       (if Descriptor.Kind = Ty.Pointer_Value
                        then Pointee_For (Source.Reference)
                        else IR.No_Pointee),
                     Length =>
                       (if Descriptor.Kind = Ty.Pointer_Value then 1 else 2),
                     others => <>);
               end;

            when Landin.Checking.Fixed_Array_Field =>
               declare
                  Element : constant IR.Field_Shape := Neutral_Shape
                    (Landin.Checking.Array_Field_Element (Types.all, Source));
               begin
                  return IR.Make_Array_Shape
                    (Unit.all, IR.Element_Total (Source.Length), Element);
               end;

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
         Element : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Array_Element_Shape (Types.all, Id);
      begin
         return Neutral_Shape (Element);
      end Neutral_Element;

      function Neutral_Element
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape
      is
         Element : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Array_Element_Shape
             (Types.all, Of_Tree, Node);
      begin
         return Neutral_Shape (Element);
      end Neutral_Element;

      function Neutral_Element
        (Part : Landin.Checking.Signature_Part) return IR.Field_Shape is
      begin
         if Part.Kind /= Ty.Fixed_Array then
            raise Landin.Compiler_Defect with
              "a non-array signature part was requested as an element";
         elsif Part.Element_Shape.Kind /= Landin.Checking.Scalar_Field
           or else Part.Element_Shape.Signature /= Landin.Checking.No_Signature
           or else Part.Element_Shape.Atoms /= Landin.Checking.No_Atom_Set
         then
            return Neutral_Shape (Part.Element_Shape);
         elsif Part.Nominal /= Landin.Checking.No_Nominal_Type then
            return Neutral_Body (Part.Nominal);
         end if;
         return
           (Kind    => IR.Scalar_Field_Shape,
            Element => Part.Element,
            Length  => 1,
            others  => <>);
      end Neutral_Element;

      function Pointee_For
        (Reference : Landin.Checking.Reference_Id) return IR.Pointee_Id
      is
         Descriptor : constant Landin.Checking.Reference_Descriptor :=
           Landin.Checking.Descriptor_Of (Types.all, Reference);
         Shape : IR.Field_Shape;
      begin
         case Descriptor.Referent is
            when Ty.Scalar_Name =>
               Shape := (Element => Descriptor.Referent, others => <>);
            when Ty.Function_Value =>
               Shape :=
                 (Element => Ty.Usize,
                  Signature => Signature_For (Descriptor.Signature),
                  others => <>);
            when Ty.Atom_Value =>
               Shape :=
                 (Element => Ty.U32, Atoms => Atom_Set_For (Descriptor.Atoms),
                  others => <>);
            when Ty.Pointer_Value =>
               Shape :=
                 (Element => Ty.Usize,
                  Pointee => Pointee_For (Descriptor.Reference), others => <>);
            when Ty.Aggregate =>
               Shape :=
                 (Kind => IR.Aggregate_Field_Shape,
                  Nominal => Nominal_For (Descriptor.Nominal), others => <>);
            when Ty.Fixed_Array =>
               declare
                  Child : constant IR.Field_Shape := Neutral_Element
                    ((Kind => Ty.Fixed_Array,
                      Element => Descriptor.Element,
                      Nominal => Descriptor.Element_Nominal,
                      Element_Shape => Descriptor.Element_Shape,
                      others => <>));
               begin
                  Shape := IR.Make_Array_Shape
                    (Unit.all, IR.Element_Total (Descriptor.Length), Child);
               end;
            when Ty.Slice_Value | Ty.Any_Value =>
               Shape :=
                 (Kind => IR.Array_Field_Shape, Element => Ty.Usize,
                  Length => 2, others => <>);
            when others =>
               raise Landin.Compiler_Defect with
                 "an incomplete pointer referent reached lowering";
         end case;
         return IR.Add_Pointee (Unit.all, Shape);
      end Pointee_For;

      function Neutral_Value_Shape
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
      begin
         if Held = Ty.Aggregate then
            return Neutral_Body
              (Landin.Checking.Nominal_Of (Types.all, Of_Tree, Node));
         elsif Held in Ty.Slice_Value | Ty.Any_Value then
            return
              (Kind => IR.Array_Field_Shape, Element => Ty.Usize,
               Length => 2, others => <>);
         elsif Held = Ty.Fixed_Array then
            declare
               Element : constant IR.Field_Shape :=
                 Neutral_Element (Of_Tree, Node);
            begin
               return IR.Make_Array_Shape
                 (Unit.all,
                  IR.Element_Total
                    (Landin.Checking.Array_Length (Types.all, Of_Tree, Node)),
                  Element);
            end;
         elsif Held in Ty.Scalar_Name | Ty.Function_Value | Ty.Pointer_Value
                         | Ty.Atom_Value
         then
            return
              (Kind => IR.Scalar_Field_Shape,
               Element => Scalar_At (Of_Tree, Node),
               Pointee =>
                 (if Held = Ty.Pointer_Value
                  then Pointee_For
                    (Landin.Checking.Reference_Of (Types.all, Of_Tree, Node))
                  else IR.No_Pointee),
               Signature =>
                 (if Held = Ty.Function_Value then Signature_For
                    (Landin.Checking.Signature_Of (Types.all, Of_Tree, Node))
                  else IR.No_Signature),
               Atoms =>
                 (if Held = Ty.Atom_Value then Atom_Set_For
                    (Landin.Checking.Atom_Set_Of (Types.all, Of_Tree, Node))
                  else IR.No_Atom_Set),
               others => <>);
         end if;
         raise Landin.Compiler_Defect with
           "a non-value was asked for a stored shape";
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

      function Evidence_Shape
        (Actual : Landin.Checking.Actual_Key) return IR.Field_Shape
      is
         Form : constant Landin.Checking.Actual_Type_Form :=
           Landin.Checking.Type_Form_Of (Actual);
      begin
         case Form is
            when Landin.Checking.Scalar_Actual_Type =>
               return
                 (Kind => IR.Scalar_Field_Shape,
                  Element => Landin.Checking.Scalar_Of (Types.all, Actual),
                  Length => 1, others => <>);
            when Landin.Checking.Atom_Set_Actual_Type =>
               return
                 (Kind => IR.Scalar_Field_Shape,
                  Element => Ty.U32, Length => 1,
                  Atoms => Atom_Set_For
                    (Landin.Checking.Atom_Set_Of (Types.all, Actual)),
                  others => <>);
            when Landin.Checking.Fixed_Array_Actual_Type =>
               declare
                  Element : constant IR.Field_Shape :=
                    (case Landin.Checking.Array_Element_Form_Of
                       (Types.all, Actual) is
                       when Landin.Checking.Nominal_Array_Element =>
                         Neutral_Body
                           (Landin.Checking.Array_Nominal_Element_Of
                              (Types.all, Actual)),
                       when Landin.Checking.Shaped_Array_Element =>
                         Neutral_Shape
                           (Landin.Checking.Array_Element_Shape_Of
                              (Types.all, Actual)),
                       when Landin.Checking.Scalar_Array_Element =>
                         (Kind => IR.Scalar_Field_Shape,
                          Element => Landin.Checking.Array_Scalar_Element_Of
                            (Types.all, Actual),
                          Length => 1, others => <>));
               begin
                  return IR.Make_Array_Shape
                    (Unit.all, IR.Element_Total
                       (Landin.Checking.Array_Length_Of (Types.all, Actual)),
                     Element);
               end;
            when Landin.Checking.Nominal_Actual_Type =>
               return Neutral_Body
                 (Landin.Checking.Nominal_Of (Types.all, Actual));
            when Landin.Checking.Function_Actual_Type =>
               return
                 (Kind => IR.Scalar_Field_Shape, Element => Ty.Usize,
                  Length => 1,
                  Signature => Signature_For
                    (Landin.Checking.Function_Signature_Of
                       (Types.all, Actual)),
                  others => <>);
            when Landin.Checking.Reference_Actual_Type =>
               declare
                  Descriptor : constant Landin.Checking.Reference_Descriptor
                    := Landin.Checking.Descriptor_Of
                      (Types.all,
                       Landin.Checking.Reference_Of (Types.all, Actual));
               begin
                  return
                    (Kind =>
                       (if Descriptor.Kind = Ty.Slice_Value
                        then IR.Array_Field_Shape
                        else IR.Scalar_Field_Shape),
                     Element => Ty.Usize,
                     Pointee =>
                       (if Descriptor.Kind = Ty.Pointer_Value
                        then Pointee_For
                          (Landin.Checking.Reference_Of (Types.all, Actual))
                        else IR.No_Pointee),
                     Length =>
                       (if Descriptor.Kind = Ty.Slice_Value then 2 else 1),
                     others => <>);
               end;
            when Landin.Checking.Any_Actual_Type =>
               return
                 (Kind => IR.Array_Field_Shape, Element => Ty.Usize,
                  Length => 2, others => <>);
         end case;
      end Evidence_Shape;

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
            when Ty.Pointer_Value =>
               return
                 (Kind => IR.Scalar_Field_Shape, Element => Ty.Usize,
                  Length => 1, Pointee => Pointee_For (Part.Reference),
                  others => <>);
            when Ty.Slice_Value | Ty.Any_Value =>
               return
                 (Kind => IR.Array_Field_Shape, Element => Ty.Usize,
                  Length => 2, others => <>);
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
               declare
                  Element : constant IR.Field_Shape := Neutral_Element (Part);
               begin
                  return IR.Make_Array_Shape
                    (Unit.all, IR.Element_Total (Part.Length), Element);
               end;
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

      --  Element operations accept either a complete nested path or the
      --  legacy direct variant selectors, never both.  Keep a direct payload
      --  compact only when no selection continues below it; otherwise the
      --  complete path must include both the payload and its child run.
      function Alias_Element_Steps
        (Of_Tree : Syn.Tree; Alias : Payload_Alias;
         Below   : IR.Path_Step_Array) return IR.Path_Step_Array;

      function Alias_Element_Steps
        (Of_Tree : Syn.Tree; Alias : Payload_Alias;
         Below   : IR.Path_Step_Array) return IR.Path_Step_Array
      is
         Steps : constant IR.Path_Step_Array := Alias_Steps (Of_Tree, Alias);
      begin
         if Alias.Which = 0 then
            return Steps & Below;
         elsif Steps'Length = 0 and then Below'Length = 0 then
            return IR.No_Path_Steps;
         else
            return Payload_Steps
              (Steps, Positive (Alias.Which), Positive (Alias.Payload_Field))
              & Below;
         end if;
      end Alias_Element_Steps;

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

      --  A `.val` reached inside a selection chain changes the root from named
      --  storage to a runtime address.  Scalar loads already recognize that
      --  boundary directly; aggregate arguments and copies must choose the
      --  same Lower_Stored_Place path instead of encoding `.val` as field
      --  zero. An inout parameter already starts at runtime storage, even
      --  when its selections contain no explicit dereference or index.
      function Has_Reference_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Where : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Of_Tree, Where)
           in Syn.Member_Selection | Syn.Element_Index
         loop
            if Syn.Kind (Of_Tree, Where) = Syn.Element_Index
              and then Type_At
                (Of_Tree, Syn.Target_Of (Of_Tree, Where)) = Ty.Slice_Value
            then
               return True;
            elsif Syn.Kind (Of_Tree, Where) = Syn.Member_Selection
              and then Landin.Checking.Field_Index
                (Types.all, Of_Tree, Where) = 0
              and then Type_At
                (Of_Tree, Syn.Target_Of (Of_Tree, Where)) = Ty.Pointer_Value
            then
               return True;
            end if;
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         if Syn.Kind (Of_Tree, Where) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Where) = Res.Bound
         then
            declare
               Means : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Where);
            begin
               if Aliases (Declared (Means)).Active
                 and then Aliases (Declared (Means)).Source.Kind
                   = IR.Runtime_Address
               then
                  return True;
               elsif Res.Sort_Of (Meanings.all, Means) = Res.Parameter then
                  return Syn.Convention_Of
                    (Tree_For (Res.Source_Of (Meanings.all, Means)).all,
                     Res.Node_Of (Meanings.all, Means)) = Syn.Inout_Convention;
               end if;
            end;
         end if;
         return False;
      end Has_Reference_Storage;

      function Lower_Stored_Place
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return Stored_Place
      is
         Result : Stored_Place;
      begin
         --  D201: a qualified binding is the storage root itself, not a
         --  zero-index field selected from a runtime namespace object.
         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
         then
            Result.Place := Storage_For (Of_Tree, Node);
            return Result;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Name_Reference =>
               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
                  Alias : Payload_Alias renames Aliases (Declared (Means));
               begin
                  --  An address names the payload leaf, not its containing
                  --  variant part, for scalar and aggregate aliases alike.
                  if Alias.Active and then Alias.Which /= 0 then
                     Result.Place := Alias.Source;
                     Result.Base := Alias.Field;
                     for Step of Payload_Steps
                       (Alias_Steps (Of_Tree, Alias),
                        Positive (Alias.Which), Positive (Alias.Payload_Field))
                     loop
                        Result.Steps.Append (Step);
                     end loop;
                     return Result;
                  end if;
               end;
               Result.Place := Rooted_Storage (Of_Tree, Node);
               Result.Base := Rooted_Base (Of_Tree, Node);
               for Step of Rooted_Steps (Of_Tree, Node) loop
                  Result.Steps.Append (Step);
               end loop;
               return Result;

            when Syn.Member_Selection =>
               if Type_At
                    (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                    = Ty.Pointer_Value
                 and then Landin.Checking.Field_Index
                   (Types.all, Of_Tree, Node) = 0
               then
                  declare
                     Pointer : constant IR.Value_Id := Lower_Expression
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
                  begin
                     if Current = IR.No_Block then
                        return Result;
                     end if;
                     declare
                        Address : constant IR.Value_Id :=
                          IR.Emit_Pointer_Address
                            (Unit.all, Filling, Pointer,
                             Site_Of (Of_Tree, Node));
                        Shape : constant IR.Field_Shape :=
                          Neutral_Value_Shape (Of_Tree, Node);
                        Slot : constant IR.Slot_Id := IR.Add_Address_Slot
                          (Unit.all, Filling, Shape, Site_Of (Of_Tree, Node));
                     begin
                        IR.Emit_Store
                          (Unit.all, Filling, Slot, Address,
                           Site_Of (Of_Tree, Node));
                        return
                          (Place => (Kind => IR.Runtime_Address,
                                     Address => Slot),
                           Base => 0,
                           Steps => Stored_Path_Vectors.Empty_Vector);
                     end;
                  end;
               end if;

               Result := Lower_Stored_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
               if Current = IR.No_Block then
                  return Result;
               end if;
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
               if Type_At
                    (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Ty.Slice_Value
               then
                  declare
                     Parts : constant Slice_Values := Lower_Slice
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
                  begin
                     if Current = IR.No_Block then
                        return Result;
                     end if;
                     declare
                        Site : constant Landin.Provenance.Origin :=
                          Site_Of (Of_Tree, Node);
                        Base : constant IR.Slot_Id := IR.Add_Slot
                          (Unit.all, Filling, Ty.Usize,
                           Res.No_Declaration, Site);
                        Length : constant IR.Slot_Id := IR.Add_Slot
                          (Unit.all, Filling, Ty.Usize,
                           Res.No_Declaration, Site);
                        Index : IR.Value_Id;
                     begin
                        --  Recovery in the index may cross blocks. Retain
                        --  the descriptor before evaluating that operand.
                        IR.Emit_Store
                          (Unit.all, Filling, Base, Parts.Base, Site);
                        IR.Emit_Store
                          (Unit.all, Filling, Length, Parts.Length, Site);
                        Index := Lower_Expression
                          (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
                        if Current = IR.No_Block then
                           return Result;
                        end if;
                        declare
                           --  Emission assigns IR identities. Sequence it
                           --  independently of argument evaluation order.
                           Saved_Base : constant IR.Value_Id :=
                             IR.Emit_Load (Unit.all, Filling, Base, Site);
                           Saved_Length : constant IR.Value_Id :=
                             IR.Emit_Load (Unit.all, Filling, Length, Site);
                           Address : constant IR.Value_Id :=
                             IR.Emit_Slice_Address
                               (Unit.all, Filling,
                                Saved_Base, Saved_Length, Index, Index,
                                Slice_Shape
                                  (Of_Tree, Syn.Target_Of (Of_Tree, Node)),
                                True, Site_Of (Of_Tree, Node));
                           Shape : constant IR.Field_Shape :=
                             Slice_Shape
                               (Of_Tree, Syn.Target_Of (Of_Tree, Node));
                           Slot : constant IR.Slot_Id := IR.Add_Address_Slot
                             (Unit.all, Filling, Shape,
                              Site_Of (Of_Tree, Node));
                        begin
                           IR.Emit_Store
                             (Unit.all, Filling, Slot, Address,
                              Site_Of (Of_Tree, Node));
                           return
                             (Place => (Kind => IR.Runtime_Address,
                                        Address => Slot),
                              Base => 0,
                              Steps => Stored_Path_Vectors.Empty_Vector);
                        end;
                     end;
                  end;
               end if;

               Result := Lower_Stored_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
               if Current = IR.No_Block then
                  return Result;
               end if;
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
            --  Storage_Address names a whole array or aggregate (or a
            --  computed element). A selected scalar is a Place_Address,
            --  with the complete path retained for its address witness.
            Address : constant IR.Value_Id :=
              (if Shape.Kind = IR.Scalar_Field_Shape
               then IR.Emit_Place_Address
                 (Unit.all, Filling, Place.Place, Site,
                  Field => Place.Base, Nested => Stored_Steps (Place))
               else IR.Emit_Storage_Address
                 (Unit.all, Filling, Place.Place, Site,
                  Field => Place.Base, Nested => Stored_Steps (Place)));
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

         if Held in Ty.Slice_Value | Ty.Any_Value then
            Slots (Positive (Id)) := IR.Add_Array_Slot
              (Unit.all, Filling, Ty.Usize, 2, Id,
               Site_Of (Of_Tree, Node));
            return Slots (Positive (Id));
         end if;

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

         if Held not in Ty.Scalar_Name | Ty.Function_Value | Ty.Pointer_Value
              | Ty.Atom_Value
         then
            raise Landin.Compiler_Defect with
              "a declaration reached the lowering with no storable type";
         end if;

         Slots (Positive (Id)) :=
           IR.Add_Slot
             (Unit.all, Filling,
              (if Held in Ty.Function_Value | Ty.Pointer_Value then Ty.Usize
               elsif Held = Ty.Atom_Value then Ty.U32
               else Ty.Scalar_Name (Held)),
              Id, Site_Of (Of_Tree, Node),
              Pointee =>
                (if Held = Ty.Pointer_Value
                 then Pointee_For
                   (Landin.Checking.Reference_Of (Types.all, Id))
                 else IR.No_Pointee),
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

         if Res.Sort_Of (Meanings.all, Means) = Res.Parameter then
            declare
               Their_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Res.Source_Of (Meanings.all, Means));
               Their_Node : constant Syn.Node_Id :=
                 Res.Node_Of (Meanings.all, Means);
            begin
               if Syn.Convention_Of (Their_Tree.all, Their_Node)
                    = Syn.Inout_Convention
               then
                  declare
                     Address : constant IR.Slot_Id :=
                       Slot_For (Of_Tree, Node, Means);
                  begin
                     pragma Assert
                       (IR.Is_Address (Unit.all, Filling, Address));
                     return
                       (Kind => IR.Runtime_Address, Address => Address);
                  end;
               end if;
            end;
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
         if Held in Ty.Slice_Value | Ty.Any_Value then
            return IR.Add_Array_Slot
              (Unit.all, Filling, Ty.Usize, 2,
               Res.No_Declaration, Site);
         end if;

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

      function Stored_At
        (Place : IR.Storage;
         Base  : Natural := 0;
         Steps : IR.Path_Step_Array := IR.No_Path_Steps) return Stored_Place;

      function Stored_At
        (Place : IR.Storage;
         Base  : Natural := 0;
         Steps : IR.Path_Step_Array := IR.No_Path_Steps) return Stored_Place
      is
         Result : Stored_Place :=
           (Place => Place, Base => Base,
            Steps => Stored_Path_Vectors.Empty_Vector);
      begin
         for Step of Steps loop
            Result.Steps.Append (Step);
         end loop;
         return Result;
      end Stored_At;

      function Shaped_Temporary
        (Shape : IR.Field_Shape; Site : Landin.Provenance.Origin)
         return IR.Slot_Id;

      function Shaped_Temporary
        (Shape : IR.Field_Shape; Site : Landin.Provenance.Origin)
         return IR.Slot_Id
      is
         Result : IR.Slot_Id;
      begin
         case Shape.Kind is
            when IR.Array_Field_Shape =>
               return IR.Add_Array_Slot
                 (Unit.all, Filling, IR.Array_Element_Shape (Unit.all, Shape),
                  Shape.Length, Res.No_Declaration, Site);
            when IR.Aggregate_Field_Shape =>
               Result := IR.Add_Aggregate_Slot
                 (Unit.all, Filling, Res.No_Declaration, Site, Shape.Nominal);
               for Field in 1 .. IR.Aggregate_Field_Count (Unit.all, Shape)
               loop
                  IR.Add_Slot_Field
                    (Unit.all, Filling, Result,
                     IR.Nth_Aggregate_Field (Unit.all, Shape, Field));
               end loop;
               return Result;
            when IR.Scalar_Field_Shape =>
               return IR.Add_Slot
                 (Unit.all, Filling, Shape.Element, Res.No_Declaration, Site,
                  Signature => Shape.Signature, Atoms => Shape.Atoms,
                  Pointee => Shape.Pointee);
            when IR.Variant_Field_Shape =>
               raise Landin.Compiler_Defect with
                 "a variant part requested standalone storage";
         end case;
      end Shaped_Temporary;

      function Child_Place
        (Parent : Stored_Place; Field : Positive; Which : Natural := 0)
         return Stored_Place;

      function Child_Place
        (Parent : Stored_Place; Field : Positive; Which : Natural := 0)
         return Stored_Place
      is
         Result : Stored_Place := Parent;
      begin
         if Which = 0 and then Result.Base = 0
           and then Result.Steps.Is_Empty
         then
            Result.Base := Field;
         else
            Result.Steps.Append
              (IR.Path_Step'(Field => IR.Part_Position (Field),
                             Case_Index => Which));
         end if;
         return Result;
      end Child_Place;

      function Array_Element_Place
        (Parent : Stored_Place; Position : Positive) return Stored_Place;

      function Array_Element_Place
        (Parent : Stored_Place; Position : Positive) return Stored_Place
      is
         Result : Stored_Place := Parent;
      begin
         --  Aggregate fields use Base for a first selection, but an array
         --  index is always a path step.  In particular, the first element
         --  of root array storage keeps Base zero so Shape_Of reaches the
         --  array before interpreting its one-based child position.
         Result.Steps.Append
           (IR.Path_Step'(Field => IR.Part_Position (Position),
                          Case_Index => 0));
         return Result;
      end Array_Element_Place;

      procedure Store_Shaped_Scalar
        (Place : Stored_Place;
         Shape : IR.Field_Shape;
         Value : IR.Value_Id;
         Site  : Landin.Provenance.Origin);

      procedure Store_Shaped_Scalar
        (Place : Stored_Place;
         Shape : IR.Field_Shape;
         Value : IR.Value_Id;
         Site  : Landin.Provenance.Origin)
      is
         Steps : constant IR.Path_Step_Array := Stored_Steps (Place);
      begin
         if Place.Place.Kind = IR.Runtime_Address then
            declare
               Address : constant IR.Storage :=
                 Addressed_Storage (Place, Shape, Site);
            begin
               IR.Emit_Store_Indirect
                 (Unit.all, Filling, Address.Address, Value, Site);
            end;
         elsif Place.Base = 0 and then Steps'Length = 0 then
            case Place.Place.Kind is
               when IR.Frame_Slot =>
                  IR.Emit_Store
                    (Unit.all, Filling, Place.Place.Slot, Value, Site);
               when IR.Module_Datum =>
                  IR.Emit_Store_Datum
                    (Unit.all, Filling, Place.Place.Datum, Value, Site);
               when IR.Runtime_Address =>
                  Impossible;
            end case;
         else
            case Place.Place.Kind is
               when IR.Frame_Slot =>
                  IR.Emit_Store_Slot_Field
                    (Unit.all, Filling, Place.Place.Slot,
                     Leaf_Base (Place.Base, Steps), Value, Site,
                     Nested => Leaf_Steps (Place.Base, Steps));
               when IR.Module_Datum =>
                  IR.Emit_Store_Field
                    (Unit.all, Filling, Place.Place.Datum,
                     Leaf_Base (Place.Base, Steps), Value, Site,
                     Nested => Leaf_Steps (Place.Base, Steps));
               when IR.Runtime_Address =>
                  Impossible;
            end case;
         end if;
      end Store_Shaped_Scalar;

      procedure Copy_Shaped_Storage
        (Source      : Stored_Place;
         Destination : Stored_Place;
         Shape       : IR.Field_Shape;
         Site        : Landin.Provenance.Origin);

      --  A whole aggregate slot is not an array-shaped root.  Preserve the
      --  selected places and their exact shape in typed runtime-address roots
      --  before using the common bytewise copy operation.  Actual arrays keep
      --  their direct storage endpoints.
      procedure Copy_Shaped_Storage
        (Source      : Stored_Place;
         Destination : Stored_Place;
         Shape       : IR.Field_Shape;
         Site        : Landin.Provenance.Origin)
      is
      begin
         if Shape.Kind = IR.Aggregate_Field_Shape then
            declare
               From : constant IR.Storage :=
                 Addressed_Storage (Source, Shape, Site);
               Into : constant IR.Storage :=
                 Addressed_Storage (Destination, Shape, Site);
            begin
               IR.Emit_Array_Copy
                 (Unit.all, Filling, From, Into, Site);
            end;
         else
            IR.Emit_Array_Copy
              (Unit.all, Filling, Source.Place, Destination.Place, Site,
               Source_Field => Source.Base,
               Source_Nested => Stored_Steps (Source),
               Destination_Field => Destination.Base,
               Destination_Nested => Stored_Steps (Destination));
         end if;
      end Copy_Shaped_Storage;

      --  One contextual writer serves array children, call temporaries and
      --  ordinary constructors.  Counts of emitted operations follow source
      --  structure, never a target-sized repetition count.
      procedure Write_Shaped_Value
        (Of_Tree     : Syn.Tree;
         Node        : Syn.Node_Id;
         Scope       : Res.Scope_Id;
         Shape       : IR.Field_Shape;
         Destination : Stored_Place);

      --  One scalar loop per lifted operator, independent of array length.
      --  Source operands are snapped left-to-right before the first element
      --  operation.  The result is private until the entire loop succeeds.
      procedure Write_Array_Arithmetic
        (Of_Tree : Syn.Tree;
         Node : Syn.Node_Id;
         Scope : Res.Scope_Id;
         Shape : IR.Field_Shape;
         Destination : Stored_Place);

      procedure Write_Array_Arithmetic
        (Of_Tree : Syn.Tree;
         Node : Syn.Node_Id;
         Scope : Res.Scope_Id;
         Shape : IR.Field_Shape;
         Destination : Stored_Place)
      is
         Site : constant Landin.Provenance.Origin := Site_Of (Of_Tree, Node);
         Unary : constant Boolean := Syn.Kind (Of_Tree, Node) = Syn.Negation;
         Updating : constant Boolean :=
           Syn.Kind (Of_Tree, Node) = Syn.Assignment;
         Count : constant Positive := (if Unary then 1 else 2);
         Child : constant IR.Field_Shape :=
           IR.Array_Element_Shape (Unit.all, Shape);
         Snapshots : array (1 .. Count) of IR.Slot_Id :=
           [others => IR.No_Slot];
         Arrays : array (1 .. Count) of Boolean := [others => False];
         Answer : IR.Slot_Id;
      begin
         for Position in Snapshots'Range loop
            declare
               Operand : constant Syn.Node_Id :=
                 (if Unary then Syn.Operand_Of (Of_Tree, Node)
                  elsif Updating then
                    (if Position = 1 then Syn.Target_Of (Of_Tree, Node)
                     else Syn.Value_Of (Of_Tree, Node))
                  elsif Position = 1 then Syn.Left_Of (Of_Tree, Node)
                  else Syn.Right_Of (Of_Tree, Node));
            begin
               Arrays (Position) :=
                 Type_At (Of_Tree, Operand) = Ty.Fixed_Array;
               Snapshots (Position) := Shaped_Temporary
                 ((if Arrays (Position) then Shape else Child), Site);
               if Updating and then Position = 1 then
                  Copy_Shaped_Storage
                    (Destination, Stored_At
                       ((Kind => IR.Frame_Slot, Slot => Snapshots (Position))),
                     Shape, Site);
               else
                  Write_Shaped_Value
                    (Of_Tree, Operand, Scope,
                     (if Arrays (Position) then Shape else Child),
                     Stored_At
                       ((Kind => IR.Frame_Slot,
                         Slot => Snapshots (Position))));
               end if;
               if Current = IR.No_Block then
                  return;
               end if;
            end;
         end loop;

         Answer := Shaped_Temporary (Shape, Site);
         if Shape.Length /= 0 then
            declare
               Cursor : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Test : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Body_Block : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Done : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               First : constant IR.Value_Id := IR.Emit_Number
                 (Unit.all, Filling, Ty.Usize, 0, False, Site);
            begin
               IR.Emit_Store (Unit.all, Filling, Cursor, First, Site);
               Close_With_Jump (Test, Site);
               Open (Test);
               declare
                  Index : constant IR.Value_Id :=
                    IR.Emit_Load (Unit.all, Filling, Cursor, Site);
                  Limit : constant IR.Value_Id := IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize,
                     Ty.Magnitude (Shape.Length), False, Site);
                  More : constant IR.Value_Id := IR.Emit_Binary
                    (Unit.all, Filling, IR.Less_Than,
                     Index, Limit, Ty.Bool, Site);
               begin
                  IR.Emit_Branch
                    (Unit.all, Filling, More, Body_Block, Done, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end;
               Open (Body_Block);
               declare
                  Index : constant IR.Value_Id :=
                    IR.Emit_Load (Unit.all, Filling, Cursor, Site);
                  Values : array (1 .. Count) of IR.Value_Id;
                  Value, One, Next : IR.Value_Id;
               begin
                  for Position in Values'Range loop
                     Values (Position) :=
                       (if Arrays (Position)
                        then IR.Emit_Load_Slot_Element
                          (Unit.all, Filling, Snapshots (Position),
                           Index, Child.Element, Site)
                        else IR.Emit_Load
                          (Unit.all, Filling, Snapshots (Position), Site));
                  end loop;
                  Value :=
                    (if Unary then IR.Emit_Unary
                       (Unit.all, Filling, IR.Negation,
                        Values (1), Child.Element, Site)
                     else IR.Emit_Binary
                       (Unit.all, Filling,
                        (if Updating then Update_Opcode
                           (Syn.Assignment_Operation (Of_Tree, Node))
                         else Opcode_For (Syn.Kind (Of_Tree, Node))),
                        Values (1), Values (2), Child.Element, Site));
                  IR.Emit_Store_Slot_Element
                    (Unit.all, Filling, Answer, Index, Value, Site);
                  One := IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 1, False, Site);
                  Next := IR.Emit_Binary
                    (Unit.all, Filling, IR.Add, Index, One, Ty.Usize, Site);
                  IR.Emit_Store (Unit.all, Filling, Cursor, Next, Site);
               end;
               Close_With_Jump (Test, Site);
               Open (Done);
            end;
         end if;
         Copy_Shaped_Storage
           (Stored_At ((Kind => IR.Frame_Slot, Slot => Answer)),
            Destination, Shape, Site);
      end Write_Array_Arithmetic;

      procedure Write_Shaped_Value
        (Of_Tree     : Syn.Tree;
         Node        : Syn.Node_Id;
         Scope       : Res.Scope_Id;
         Shape       : IR.Field_Shape;
         Destination : Stored_Place)
      is
         Site : constant Landin.Provenance.Origin := Site_Of (Of_Tree, Node);
         Kind : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
      begin
         if Landin.Checking.Distinct_Conversion_Of
           (Types.all, Of_Tree, Node) /= Landin.Checking.No_Nominal_Type
           and then Shape.Kind /= IR.Scalar_Field_Shape
         then
            declare
               Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Distinct_Conversion_Of
                   (Types.all, Of_Tree, Node);
               Value : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, 1);
            begin
               if Type_At (Of_Tree, Node) = Ty.Aggregate
                 and then Landin.Checking.Nominal_Of
                   (Types.all, Of_Tree, Node) = Nominal
               then
                  Write_Shaped_Value
                    (Of_Tree, Value, Scope,
                     Neutral_Result_Part
                       (Landin.Checking.Distinct_Base (Types.all, Nominal)),
                     Child_Place (Destination, 1));
               else
                  declare
                     Temporary : constant IR.Slot_Id := Shaped_Temporary
                       (Neutral_Value_Shape (Of_Tree, Value), Site);
                  begin
                     Lower_Stored_Expression
                       (Of_Tree, Value, Scope, Temporary);
                     if Current /= IR.No_Block then
                        Copy_Shaped_Storage
                          (Child_Place
                             (Stored_At
                                ((Kind => IR.Frame_Slot, Slot => Temporary)),
                              1),
                           Destination, Shape, Site);
                     end if;
                  end;
               end if;
            end;
         elsif Shape.Kind = IR.Scalar_Field_Shape then
            declare
               Value : constant IR.Value_Id :=
                 Lower_Expression (Of_Tree, Node, Scope);
            begin
               if Current /= IR.No_Block then
                  Store_Shaped_Scalar (Destination, Shape, Value, Site);
               end if;
            end;
         elsif Shape.Kind = IR.Array_Field_Shape
           and then Kind in Syn.Negation | Syn.Add | Syn.Subtract
             | Syn.Multiply | Syn.Divide | Syn.Remainder | Syn.Wrapping_Add
             | Syn.Wrapping_Subtract | Syn.Wrapping_Multiply
         then
            Write_Array_Arithmetic
              (Of_Tree, Node, Scope, Shape, Destination);
         elsif Kind = Syn.Zeroed_Literal then
            IR.Emit_Array_Clear
              (Unit.all, Filling, Destination.Place, Site,
               Field => Destination.Base,
               Nested => Stored_Steps (Destination));
         elsif Shape.Kind = IR.Aggregate_Field_Shape
           and then Is_Struct_Construction (Of_Tree, Node)
         then
            declare
               Seen : array (1 .. IR.Aggregate_Field_Count (Unit.all, Shape))
                 of Boolean := [others => False];
            begin
               --  D29 commits labels in source order; D64 fills omitted
               --  fields only afterwards, never clearing a value a label
               --  can still read from the destination.
               for Written in 1 .. Construction_Field_Count (Of_Tree, Node)
               loop
                  declare
                     Label : constant Syn.Node_Id :=
                       Nth_Construction_Field (Of_Tree, Node, Written);
                     Field : constant Positive := Positive
                       (Landin.Checking.Field_Index
                          (Types.all, Of_Tree, Label));
                  begin
                     Seen (Field) := True;
                     Write_Shaped_Value
                       (Of_Tree, Construction_Field_Value (Of_Tree, Label),
                        Scope, IR.Nth_Aggregate_Field (Unit.all, Shape, Field),
                        Child_Place (Destination, Field));
                     if Current = IR.No_Block then
                        return;
                     end if;
                  end;
               end loop;
               if Construction_Fill (Of_Tree, Node) /= Syn.No_Node
                 and then Syn.Kind
                   (Of_Tree, Construction_Fill (Of_Tree, Node))
                     /= Syn.Zeroed_Literal
               then
                  declare
                     Fill : constant Syn.Node_Id :=
                       Construction_Fill (Of_Tree, Node);
                     First_Missing : Positive := Seen'First;
                  begin
                     while Seen (First_Missing) loop
                        First_Missing := First_Missing + 1;
                     end loop;
                     declare
                        Child : constant IR.Field_Shape :=
                          IR.Nth_Aggregate_Field
                            (Unit.all, Shape, First_Missing);
                        Saved : constant IR.Slot_Id :=
                          Shaped_Temporary (Child, Site_Of (Of_Tree, Fill));
                        Place : constant Stored_Place :=
                          Stored_At ((Kind => IR.Frame_Slot, Slot => Saved));
                     begin
                        Write_Shaped_Value
                          (Of_Tree, Fill, Scope, Child, Place);
                        if Current = IR.No_Block then
                           return;
                        end if;
                        for Field in Seen'Range loop
                           if not Seen (Field) then
                              if Child.Kind = IR.Scalar_Field_Shape then
                                 Store_Shaped_Scalar
                                   (Child_Place (Destination, Field), Child,
                                    IR.Emit_Load
                                      (Unit.all, Filling, Saved, Site), Site);
                              else
                                 Copy_Shaped_Storage
                                   (Place, Child_Place (Destination, Field),
                                    Child, Site);
                              end if;
                           end if;
                        end loop;
                     end;
                  end;
               elsif Construction_Fill (Of_Tree, Node) /= Syn.No_Node then
                  for Field in Seen'Range loop
                     if not Seen (Field) then
                        declare
                           Child : constant IR.Field_Shape :=
                             IR.Nth_Aggregate_Field (Unit.all, Shape, Field);
                           Place : constant Stored_Place :=
                             Child_Place (Destination, Field);
                           Zero : IR.Value_Id;
                        begin
                           case Child.Kind is
                              when IR.Scalar_Field_Shape =>
                                 if Child.Signature /= IR.No_Signature
                                   or else Child.Atoms /= IR.No_Atom_Set
                                 then
                                    raise Landin.Compiler_Defect with
                                      "a nonzeroable scalar reached a fill";
                                 elsif Child.Element = Ty.Bool then
                                    Zero := IR.Emit_Truth
                                      (Unit.all, Filling, False, Site);
                                 else
                                    Zero := IR.Emit_Number
                                      (Unit.all, Filling, Child.Element,
                                       0, False, Site);
                                 end if;
                                 Store_Shaped_Scalar
                                   (Place, Child, Zero, Site);
                              when IR.Array_Field_Shape
                                 | IR.Aggregate_Field_Shape =>
                                 IR.Emit_Array_Clear
                                   (Unit.all, Filling, Place.Place, Site,
                                    Field => Place.Base,
                                    Nested => Stored_Steps (Place));
                              when IR.Variant_Field_Shape =>
                                 IR.Emit_Variant_Select
                                   (Unit.all, Filling, Place.Place,
                                    Positive (Place.Base), 1, Site,
                                    Nested => Stored_Steps (Place));
                           end case;
                        end;
                     end if;
                  end loop;
               end if;
            end;
         elsif Shape.Kind = IR.Variant_Field_Shape then
            declare
               Which : constant Positive := Positive
                 (Landin.Checking.Field_Index (Types.all, Of_Tree, Node));
               Seen : array
                 (1 .. IR.Variant_Case_Field_Count (Unit.all, Shape, Which))
                   of Boolean := [others => False];
            begin
               IR.Emit_Variant_Select
                 (Unit.all, Filling, Destination.Place,
                  Positive (Destination.Base), Which, Site,
                  Nested => Stored_Steps (Destination));
               if Is_Case_Construction (Of_Tree, Node) then
                  for Written in 1 .. Construction_Field_Count (Of_Tree, Node)
                  loop
                     declare
                        Label : constant Syn.Node_Id :=
                          Nth_Construction_Field (Of_Tree, Node, Written);
                        Field : constant Positive := Positive
                          (Landin.Checking.Field_Index
                             (Types.all, Of_Tree, Label));
                     begin
                        Seen (Field) := True;
                        Write_Shaped_Value
                          (Of_Tree, Construction_Field_Value (Of_Tree, Label),
                           Scope, IR.Nth_Variant_Case_Field
                             (Unit.all, Shape, Which, Field),
                           Child_Place (Destination, Field, Which));
                        exit when Current = IR.No_Block;
                     end;
                  end loop;
                  if Current /= IR.No_Block
                    and then Construction_Fill (Of_Tree, Node) /= Syn.No_Node
                    and then Syn.Kind
                      (Of_Tree, Construction_Fill (Of_Tree, Node))
                        /= Syn.Zeroed_Literal
                  then
                     declare
                        Fill : constant Syn.Node_Id :=
                          Construction_Fill (Of_Tree, Node);
                        First_Missing : Positive := Seen'First;
                     begin
                        while Seen (First_Missing) loop
                           First_Missing := First_Missing + 1;
                        end loop;
                        declare
                           Child : constant IR.Field_Shape :=
                             IR.Nth_Variant_Case_Field
                               (Unit.all, Shape, Which, First_Missing);
                           Saved : constant IR.Slot_Id :=
                             Shaped_Temporary (Child, Site_Of (Of_Tree, Fill));
                           Place : constant Stored_Place :=
                             Stored_At
                               ((Kind => IR.Frame_Slot, Slot => Saved));
                        begin
                           Write_Shaped_Value
                             (Of_Tree, Fill, Scope, Child, Place);
                           if Current = IR.No_Block then
                              return;
                           end if;
                           for Field in Seen'Range loop
                              if not Seen (Field) then
                                 if Child.Kind = IR.Scalar_Field_Shape then
                                    Store_Shaped_Scalar
                                      (Child_Place
                                         (Destination, Field, Which), Child,
                                       IR.Emit_Load
                                         (Unit.all, Filling, Saved, Site),
                                       Site);
                                 else
                                    Copy_Shaped_Storage
                                      (Place, Child_Place
                                         (Destination, Field, Which),
                                       Child, Site);
                                 end if;
                              end if;
                           end loop;
                        end;
                     end;
                  end if;
               end if;
            end;
         elsif Shape.Kind = IR.Array_Field_Shape
           and then Kind in Syn.Array_Literal | Syn.Array_Repetition
                           | Syn.Mixed_Array_Repetition
         then
            declare
               Child : constant IR.Field_Shape :=
                 IR.Array_Element_Shape (Unit.all, Shape);
               Prefix : constant Natural :=
                 (if Kind = Syn.Array_Repetition then 0
                  else Syn.Element_Count (Of_Tree, Node));
            begin
               for Position in 1 .. Prefix loop
                  Write_Shaped_Value
                    (Of_Tree, Syn.Nth_Element (Of_Tree, Node, Position), Scope,
                     Child, Array_Element_Place (Destination, Position));
                  if Current = IR.No_Block then
                     return;
                  end if;
               end loop;
               if Kind in Syn.Array_Repetition | Syn.Mixed_Array_Repetition
               then
                  declare
                     Repeated : constant Syn.Node_Id :=
                       Syn.Repeated_Element (Of_Tree, Node);
                  begin
                     if Child.Kind = IR.Scalar_Field_Shape then
                        declare
                           Value : constant IR.Value_Id :=
                             Lower_Expression (Of_Tree, Repeated, Scope);
                        begin
                           if Current /= IR.No_Block
                             and then IR.Element_Total (Prefix) < Shape.Length
                           then
                              IR.Emit_Array_Fill
                                (Unit.all, Filling, Destination.Place,
                                 IR.Part_Position (Prefix + 1), Value, Site,
                                 Field => Destination.Base,
                                 Nested => Stored_Steps (Destination));
                           end if;
                        end;
                     else
                        declare
                           Temporary : constant IR.Slot_Id :=
                             Shaped_Temporary (Child, Site);
                           Source : constant IR.Storage :=
                             (Kind => IR.Frame_Slot, Slot => Temporary);
                        begin
                           --  Evaluate even an empty suffix once; only the
                           --  copying loop is conditional on its extent.
                           Write_Shaped_Value
                             (Of_Tree, Repeated, Scope, Child,
                              (Place => Source, Base => 0,
                               Steps => Stored_Path_Vectors.Empty_Vector));
                           if Current = IR.No_Block
                             or else IR.Element_Total (Prefix) = Shape.Length
                           then
                              return;
                           end if;
                           declare
                              Cursor : constant IR.Slot_Id := IR.Add_Slot
                                (Unit.all, Filling, Ty.Usize,
                                 Res.No_Declaration, Site);
                              First : constant IR.Value_Id := IR.Emit_Number
                                (Unit.all, Filling, Ty.Usize,
                                 Ty.Magnitude (Prefix), False, Site);
                              Test : constant IR.Block_Id :=
                                Fresh (Of_Tree, Node, Scope);
                              Body_Block : constant IR.Block_Id :=
                                Fresh (Of_Tree, Node, Scope);
                              Done : constant IR.Block_Id :=
                                Fresh (Of_Tree, Node, Scope);
                           begin
                              IR.Emit_Store
                                (Unit.all, Filling, Cursor, First, Site);
                              Close_With_Jump (Test, Site);
                              Open (Test);
                              declare
                                 Index : constant IR.Value_Id :=
                                   IR.Emit_Load
                                     (Unit.all, Filling, Cursor, Site);
                                 Limit : constant IR.Value_Id := IR.Emit_Number
                                   (Unit.all, Filling, Ty.Usize,
                                    Ty.Magnitude (Shape.Length), False, Site);
                                 More : constant IR.Value_Id := IR.Emit_Binary
                                   (Unit.all, Filling, IR.Less_Than,
                                    Index, Limit, Ty.Bool, Site);
                              begin
                                 IR.Emit_Branch
                                   (Unit.all, Filling, More,
                                    Body_Block, Done, Site);
                                 IR.Leave_Block (Unit.all, Filling);
                                 Current := IR.No_Block;
                              end;
                              Open (Body_Block);
                              declare
                                 Index : constant IR.Value_Id :=
                                   IR.Emit_Load
                                     (Unit.all, Filling, Cursor, Site);
                                 Pointer : constant IR.Value_Id :=
                                   IR.Emit_Storage_Address
                                     (Unit.all, Filling,
                                      Destination.Place, Site,
                                      Field => Destination.Base,
                                      Nested => Stored_Steps (Destination),
                                      Index => Index);
                                 Address : constant IR.Slot_Id :=
                                   IR.Add_Address_Slot
                                     (Unit.all, Filling, Child, Site);
                                 One : IR.Value_Id;
                                 Next : IR.Value_Id;
                              begin
                                 IR.Emit_Store
                                   (Unit.all, Filling, Address, Pointer, Site);
                                 Copy_Shaped_Storage
                                   (Stored_At (Source),
                                    (Place =>
                                       (Kind => IR.Runtime_Address,
                                        Address => Address),
                                     Base => 0,
                                     Steps =>
                                       Stored_Path_Vectors.Empty_Vector),
                                    Child, Site);
                                 One := IR.Emit_Number
                                   (Unit.all, Filling, Ty.Usize,
                                    1, False, Site);
                                 Next := IR.Emit_Binary
                                   (Unit.all, Filling, IR.Add, Index, One,
                                    Ty.Usize, Site);
                                 IR.Emit_Store
                                   (Unit.all, Filling, Cursor, Next, Site);
                              end;
                              Close_With_Jump (Test, Site);
                              Open (Done);
                           end;
                        end;
                     end if;
                  end;
               end if;
            end;
         elsif Kind in Syn.Name_Reference | Syn.Member_Selection
                       | Syn.Element_Index
           and then not Is_Utf8_Index (Of_Tree, Node)
         then
            declare
               From : constant Stored_Place :=
                 Lower_Stored_Place (Of_Tree, Node, Scope);
            begin
               if Current /= IR.No_Block then
                  Copy_Shaped_Storage (From, Destination, Shape, Site);
               end if;
            end;
         else
            declare
               Temporary : constant IR.Slot_Id :=
                 Shaped_Temporary (Shape, Site);
            begin
               Lower_Stored_Expression (Of_Tree, Node, Scope, Temporary);
               if Current /= IR.No_Block then
                  Copy_Shaped_Storage
                    ((Place =>
                        (Kind => IR.Frame_Slot, Slot => Temporary),
                      Base => 0,
                      Steps => Stored_Path_Vectors.Empty_Vector),
                     Destination, Shape, Site);
               end if;
            end;
         end if;
      end Write_Shaped_Value;

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
         if Held in Ty.Scalar_Name | Ty.Atom_Value | Ty.Pointer_Value then
            Answer := IR.Add_Slot
              (Unit.all, Filling,
               (if Held = Ty.Atom_Value then Ty.U32
                elsif Held = Ty.Pointer_Value then Ty.Usize
                else Ty.Scalar_Name (Held)),
               Res.No_Declaration, Site,
               Pointee =>
                 (if Held = Ty.Pointer_Value
                  then Pointee_For
                    (Landin.Checking.Reference_Of (Types.all, Of_Tree, Node))
                  else IR.No_Pointee),
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
            when Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               Lower_Loop
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
         if Landin.Checking.Distinct_Conversion_Of
           (Types.all, Of_Tree, Node) /= Landin.Checking.No_Nominal_Type
           or else Is_Struct_Construction (Of_Tree, Node)
           or else Syn.Kind (Of_Tree, Node)
             in Syn.Array_Literal | Syn.Array_Repetition
                | Syn.Mixed_Array_Repetition | Syn.Zeroed_Literal
           or else
             (Type_At (Of_Tree, Node) in Ty.Aggregate | Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node)
                in Syn.Name_Reference | Syn.Member_Selection
                   | Syn.Element_Index | Syn.Negation | Syn.Add
                   | Syn.Subtract | Syn.Multiply | Syn.Divide | Syn.Remainder
                   | Syn.Wrapping_Add | Syn.Wrapping_Subtract
                   | Syn.Wrapping_Multiply
              and then not Is_Utf8_Index (Of_Tree, Node))
         then
            declare
               Shape : constant IR.Field_Shape :=
                 Neutral_Value_Shape (Of_Tree, Node);
            begin
               Write_Shaped_Value
                 (Of_Tree, Node, Scope, Shape,
                  Stored_At
                    ((Kind => IR.Frame_Slot, Slot => Destination),
                     Destination_Field, Destination_Path));
            end;
            return;
         end if;
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Inclusive_Slice | Syn.Half_Open_Slice
               | Syn.Empty_Slice_Literal | Syn.Text_Literal
               | Syn.Raw_Literal
               | Syn.Any_Construction
               | Syn.Name_Reference | Syn.Member_Selection =>
               if Destination_Field /= 0 or else Destination_Path'Length /= 0
               then
                  raise Landin.Compiler_Defect with
                    "a nested slice destination reached direct lowering";
               end if;
               Lower_Slice_Into (Of_Tree, Node, Scope, Destination);
            when Syn.Element_Index =>
               if not Is_Utf8_Index (Of_Tree, Node)
                 or else Destination_Field /= 0
                 or else Destination_Path'Length /= 0
               then
                  raise Landin.Compiler_Defect with
                    "a non-text or nested index reached stored lowering";
               end if;
               Lower_Slice_Into (Of_Tree, Node, Scope, Destination);
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
            when Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               Lower_Loop
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
           Syn.Kind (Of_Tree, Callee)
             in Syn.Name_Reference | Syn.Member_Selection
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
         Erased_Self : constant Boolean :=
           Syn.Kind (Of_Tree, Callee) = Syn.Member_Selection
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Callee)
             /= Res.Bound
           and then Type_At
             (Of_Tree, Syn.Target_Of (Of_Tree, Callee)) = Ty.Any_Value;
         Parameter_Offset : constant Natural :=
           (if Erased_Self then 1 else 0);
         Source_Signature : constant Landin.Checking.Signature_Id :=
           (if Generic_Target /= Landin.Checking.No_Routine_Instance
            then Landin.Checking.Routine_Signature_Of
              (Types.all, Generic_Target)
            elsif Named
            then Landin.Checking.Signature_Of (Types.all, Means)
            else Landin.Checking.Signature_Of
              (Types.all, Of_Tree, Callee));
         Dispatch_Evidence : constant IR.Evidence_Id :=
           (if Erased_Self then Any_Evidence_For
              (Landin.Checking.Evidence_Of (Types.all, Of_Tree, Callee))
            else IR.No_Evidence);
         Dispatch_Entry : constant Natural :=
           (if Erased_Self then Landin.Checking.Evidence_Entry_Of
              (Types.all, Of_Tree, Callee) else 0);
         Signature : constant IR.Signature_Id :=
           (if Erased_Self then IR.Evidence_Entry_Dispatch_Signature
              (Unit.all, Dispatch_Evidence, Positive (Dispatch_Entry))
            elsif Source_Signature = Landin.Checking.No_Signature
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
         Written_Count : constant Natural :=
           Syn.Argument_Count (Of_Tree, Node);
         Count : constant Natural :=
           (if Source_Signature = Landin.Checking.No_Signature
            then 0
            else Landin.Checking.Signature_Parameter_Count
              (Types.all, Source_Signature));
         Variadic : constant Boolean :=
           Source_Signature /= Landin.Checking.No_Signature
           and then Landin.Checking.Signature_Is_Variadic
             (Types.all, Source_Signature);
         Actual_Count : constant Natural :=
           (if Variadic then Natural'Max (Count, Written_Count) else Count);
         Returns_Stored : constant Boolean :=
           Type_At (Of_Tree, Node)
             in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
                | Ty.Any_Value;
         Given : array (1 .. Positive'Max (1, Actual_Count)) of IR.Value_Id :=
           [others => IR.No_Value];
         Saved : array (1 .. Positive'Max (1, Actual_Count)) of IR.Slot_Id :=
           [others => IR.No_Slot];
         Evidence_Count : constant Natural :=
           (if Generic_Target = Landin.Checking.No_Routine_Instance
            then 0
            else Landin.Checking.Routine_Evidence_Count
              (Types.all, Generic_Target));
         Evidence_Arguments : array
           (1 .. Positive'Max (1, Evidence_Count)) of IR.Value_Id :=
             [others => IR.No_Value];
         Hidden : IR.Value_Id := IR.No_Value;
         Callee_Saved : IR.Slot_Id := IR.No_Slot;
         Receiver_Saved : IR.Slot_Id := IR.No_Slot;
         Callee_Value : IR.Value_Id := IR.No_Value;
         Error_Set : constant IR.Atom_Set_Id :=
           (if Signature = IR.No_Signature
            then IR.No_Atom_Set
            else IR.Signature_Errors (Unit.all, Signature));
         Failure_Slot : IR.Slot_Id := IR.No_Slot;
         Success_Slot : IR.Slot_Id := IR.No_Slot;
         Made : IR.Value_Id;

         function Has_Runtime_After (Written : Natural) return Boolean;

         function Nth_Written_Parameter (Index : Positive) return Positive;

         function Has_Runtime_After (Written : Natural) return Boolean is
         begin
            for Later in Written + 1 .. Written_Count loop
               declare
                  Argument : constant Syn.Node_Id :=
                    Syn.Nth_Argument (Of_Tree, Node, Later);
               begin
                  if Syn.Kind (Of_Tree, Argument) /= Syn.Call_Argument
                    or else Res.Role_Of (Meanings.all, Of_Tree, Argument)
                      not in Res.Type_Argument | Res.Fixed_Argument
                  then
                     return True;
                  end if;
               end;
            end loop;
            return False;
         end Has_Runtime_After;

         function Nth_Written_Parameter (Index : Positive) return Positive is
            Seen : Natural := 0;
         begin
            for Position in Parameter_Offset + 1 .. Count loop
               if not Landin.Checking.Nth_Signature_Parameter
                 (Types.all, Source_Signature, Position).Caller
               then
                  Seen := Seen + 1;
                  if Seen = Index then
                     return Position;
                  end if;
               end if;
            end loop;
            if Variadic and then Index > Seen then
               return Count + Index - Seen;
            end if;
            raise Landin.Compiler_Defect with
              "a lowered written argument has no source parameter";
         end Nth_Written_Parameter;
      begin
         if Landin.Checking.Distinct_Conversion_Of
           (Types.all, Of_Tree, Node) /= Landin.Checking.No_Nominal_Type
         then
            if Returns_Stored then
               declare
                  Shape : constant IR.Field_Shape :=
                    Neutral_Value_Shape (Of_Tree, Node);
                  Slot : constant IR.Slot_Id :=
                    (if Destination = IR.No_Slot
                     then Shaped_Temporary (Shape, Site)
                     else Destination);
                  Place : Stored_Place :=
                    (Place => (Kind => IR.Frame_Slot, Slot => Slot),
                     Base => Destination_Field,
                     Steps => Stored_Path_Vectors.Empty_Vector);
               begin
                  for Step of Destination_Steps loop
                     Place.Steps.Append (Step);
                  end loop;
                  Write_Shaped_Value (Of_Tree, Node, Scope, Shape, Place);
                  return IR.No_Value;
               end;
            else
               return Lower_Expression (Of_Tree, Node, Scope);
            end if;
         end if;
         if Source_Signature = Landin.Checking.No_Signature
           or else Signature = IR.No_Signature
           or else
             (Syn.Kind (Of_Tree, Node) = Syn.Labeled_Application
              and then Res.Match_Of (Meanings.all, Of_Tree, Node)
                         /= Res.Call_Matched)
         then
            raise Landin.Compiler_Defect with
              "a call reached lowering without a complete checked match";
         end if;

         if Error_Set /= IR.No_Atom_Set then
            Failure_Slot := IR.Add_Slot
              (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site,
               Atoms => Error_Set);
            if Type_At (Of_Tree, Node)
                 in Ty.Scalar_Name | Ty.Function_Value | Ty.Pointer_Value
                    | Ty.Atom_Value
            then
               Success_Slot := IR.Add_Slot
                 (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                  Res.No_Declaration, Site,
                  Pointee =>
                    (if Type_At (Of_Tree, Node) = Ty.Pointer_Value
                     then Pointee_For (Landin.Checking.Reference_Of
                       (Types.all, Of_Tree, Node))
                     else IR.No_Pointee),
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
         if Erased_Self then
            --  [0410]: choose the whole receiver once, before written
            --  arguments can replace its original binding or change blocks.
            Receiver_Saved := IR.Add_Array_Slot
              (Unit.all, Filling, Ty.Usize, 2, Res.No_Declaration, Site);
            Lower_Slice_Into
              (Of_Tree, Syn.Target_Of (Of_Tree, Callee), Scope,
               Receiver_Saved);
            if Current = IR.No_Block then
               return IR.No_Value;
            end if;
         elsif Indirect then
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
         for Written in 1 .. Written_Count loop
            if Syn.Kind
                 (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Written))
                   = Syn.Call_Argument
              and then Res.Role_Of
                (Meanings.all, Of_Tree,
                 Syn.Nth_Argument (Of_Tree, Node, Written))
                   in Res.Type_Argument | Res.Fixed_Argument
            then
               goto Next_Runtime_Argument;
            end if;
            declare
               Raw_Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, Written);
               Formal_Position : constant Positive :=
                 (if Syn.Kind (Of_Tree, Raw_Argument) = Syn.Call_Argument
                  then Positive
                    (Res.Position_Of
                       (Meanings.all, Of_Tree, Raw_Argument))
                  else Nth_Written_Parameter (Written));
               Argument : constant Syn.Node_Id :=
                 (if Syn.Kind (Of_Tree, Raw_Argument) = Syn.Call_Argument
                  then Syn.Expression_Projection (Of_Tree, Raw_Argument)
                  else Raw_Argument);
               Parameter : constant Landin.Checking.Signature_Part :=
                 (if Formal_Position <= Count
                  then Landin.Checking.Nth_Signature_Parameter
                    (Types.all, Source_Signature, Formal_Position)
                  else (Kind => Type_At (Of_Tree, Argument), others => <>));
            begin
               if Formal_Position > Count
                 and then Type_At (Of_Tree, Argument)
                   not in Ty.Scalar_Name | Ty.Pointer_Value | Ty.Function_Value
               then
                  raise Landin.Compiler_Defect with
                    "a non-scalar variadic tail needs an explicit descriptor";
               end if;
               if Parameter.Convention = Syn.Inout_Convention then
                  declare
                     Place : constant Stored_Place :=
                       Lower_Stored_Place (Of_Tree, Argument, Scope);
                     Site : constant Landin.Provenance.Origin :=
                       Site_Of (Of_Tree, Argument);
                  begin
                     --  An inout forwarded from another inout already is the
                     --  address the callee needs. Taking its place address
                     --  would instead pass the address slot itself.
                     if Place.Place.Kind = IR.Runtime_Address
                       and then Place.Base = 0
                       and then Place.Steps.Is_Empty
                     then
                        Given (Formal_Position) := IR.Emit_Load
                          (Unit.all, Filling, Place.Place.Address, Site);
                     else
                        Given (Formal_Position) := IR.Emit_Place_Address
                          (Unit.all, Filling, Place.Place, Site,
                           Field => Place.Base,
                           Nested => Stored_Steps (Place));
                     end if;
                  end;
               elsif Type_At (Of_Tree, Argument)
                    in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
                       | Ty.Any_Value
               then
                  if Type_At (Of_Tree, Argument)
                       in Ty.Slice_Value | Ty.Any_Value
                    and then Syn.Kind (Of_Tree, Argument)
                      not in Syn.Call | Syn.Labeled_Application
                         | Syn.Try_Expression
                         | Syn.If_Statement | Syn.Match_Statement
                         | Syn.Bare_Block | Syn.Loop_Statement
                         | Syn.While_Statement | Syn.For_Statement
                  then
                     declare
                        Temporary : constant IR.Slot_Id :=
                          Add_Value_Temporary (Of_Tree, Argument);
                     begin
                        Lower_Slice_Into
                          (Of_Tree, Argument, Scope, Temporary);
                        Given (Formal_Position) := IR.Emit_Storage_Address
                          (Unit.all, Filling,
                           (Kind => IR.Frame_Slot, Slot => Temporary),
                           Site_Of (Of_Tree, Argument));
                     end;
                  elsif Syn.Kind (Of_Tree, Argument)
                       in Syn.Call | Syn.Labeled_Application
                          | Syn.Try_Expression | Syn.If_Statement
                          | Syn.Match_Statement | Syn.Bare_Block
                          | Syn.Loop_Statement | Syn.While_Statement
                          | Syn.For_Statement
                    and then not Is_Struct_Construction (Of_Tree, Argument)
                  then
                     declare
                        Temporary : constant IR.Slot_Id :=
                          Add_Value_Temporary (Of_Tree, Argument);
                     begin
                        Lower_Stored_Expression
                          (Of_Tree, Argument, Scope, Temporary);
                        if Current /= IR.No_Block then
                           Given (Formal_Position) := IR.Emit_Storage_Address
                             (Unit.all, Filling,
                              (Kind => IR.Frame_Slot, Slot => Temporary),
                              Site_Of (Of_Tree, Argument));
                        end if;
                     end;
                  elsif Syn.Kind (Of_Tree, Argument)
                          in Syn.Zeroed_Literal | Syn.Array_Literal
                             | Syn.Array_Repetition
                             | Syn.Mixed_Array_Repetition
                             | Syn.Negation | Syn.Add | Syn.Subtract
                             | Syn.Multiply | Syn.Divide | Syn.Remainder
                             | Syn.Wrapping_Add | Syn.Wrapping_Subtract
                             | Syn.Wrapping_Multiply
                    or else Is_Struct_Construction (Of_Tree, Argument)
                  then
                     declare
                        Shape : constant IR.Field_Shape :=
                          Neutral_Result_Part (Parameter);
                        Temporary : constant IR.Slot_Id := Shaped_Temporary
                          (Shape, Site_Of (Of_Tree, Argument));
                        Place : constant IR.Storage :=
                          (Kind => IR.Frame_Slot, Slot => Temporary);
                     begin
                        Write_Shaped_Value
                          (Of_Tree, Argument, Scope, Shape, Stored_At (Place));
                        if Current /= IR.No_Block then
                           Given (Formal_Position) := IR.Emit_Storage_Address
                             (Unit.all, Filling, Place,
                              Site_Of (Of_Tree, Argument));
                        end if;
                     end;
                  elsif Has_Runtime_After (Written)
                    and then Parameter.Convention /= Syn.Inout_Convention
                    and then Type_At (Of_Tree, Argument)
                               in Ty.Aggregate | Ty.Fixed_Array
                  then
                     --  [0410]/D94: an `in` aggregate is a value, evaluated
                     --  where it is written.  Its address alone kept its
                     --  identity across the later arguments but not its
                     --  bytes, so a later argument's side effect reached
                     --  the callee.  A caller temporary takes the bytes
                     --  now; `inout` keeps naming the place.
                     declare
                        Reached : constant Stored_Place :=
                          Lower_Stored_Place (Of_Tree, Argument, Scope);
                     begin
                        if Current = IR.No_Block then
                           return IR.No_Value;
                        end if;
                        declare
                           Here : constant Landin.Provenance.Origin :=
                             Site_Of (Of_Tree, Argument);
                           From : constant IR.Storage :=
                             Addressed_Storage
                               (Reached,
                                Neutral_Value_Shape (Of_Tree, Argument),
                                Here);
                           Is_Struct : constant Boolean :=
                             Type_At (Of_Tree, Argument) = Ty.Aggregate;
                           Temporary : constant IR.Slot_Id :=
                             (if Is_Struct
                              then IR.Add_Aggregate_Slot
                                (Unit.all, Filling, Res.No_Declaration,
                                 Here, Nominal_For (Parameter.Nominal))
                              else IR.Add_Array_Slot
                                (Unit.all, Filling,
                                 Neutral_Element (Parameter),
                                 IR.Element_Total (Parameter.Length),
                                 Res.No_Declaration, Here));
                        begin
                           if Is_Struct then
                              for Field in
                                1 .. Landin.Checking.Layout_Field_Count
                                       (Types.all, Parameter.Nominal)
                              loop
                                 Add_Stored_Field
                                   (Parameter.Nominal, Field,
                                    Slot => Temporary);
                              end loop;
                           end if;
                           IR.Emit_Array_Copy
                             (Unit.all, Filling, From,
                              Addressed_Storage
                                ((Place => (Kind => IR.Frame_Slot,
                                            Slot => Temporary),
                                  Base  => 0,
                                  Steps => Stored_Path_Vectors.Empty_Vector),
                                 Neutral_Value_Shape (Of_Tree, Argument),
                                 Here),
                              Here);
                           Given (Formal_Position) := IR.Emit_Storage_Address
                             (Unit.all, Filling,
                              (Kind => IR.Frame_Slot, Slot => Temporary),
                              Here);
                        end;
                     end;
                  else
                     if Has_Computed_Index (Of_Tree, Argument)
                       or else Has_Reference_Storage (Of_Tree, Argument)
                     then
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
                              Given (Formal_Position) :=
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
                           Given (Formal_Position) :=
                             IR.Emit_Storage_Address
                               (Unit.all, Filling, Rooted_Storage
                                  (Of_Tree, Argument),
                                Site_Of (Of_Tree, Argument),
                                Field => Field, Nested => Child_Steps);
                        end;
                     end if;
                  end if;
               else
                  Given (Formal_Position) :=
                    Lower_Expression (Of_Tree, Argument, Scope);
               end if;

               if Current = IR.No_Block then
                  return IR.No_Value;
               end if;

               if Formal_Position > Count then
                  --  The callee keeps its fixed prototype.  Tail operand
                  --  kinds carry the promoted C actual types to the backend
                  --  without inventing a different callable identity.
                  declare
                     Held : constant Ty.Scalar_Name :=
                       Scalar_At (Of_Tree, Argument);
                     Promoted : constant Ty.Scalar_Name :=
                       (if Held in Ty.Bool | Ty.I8 | Ty.U8 | Ty.I16 | Ty.U16
                        then Ty.I32
                        elsif Held = Ty.F32 then Ty.F64 else Held);
                  begin
                     if Held /= Promoted then
                        Given (Formal_Position) := IR.Emit_Conversion
                          (Unit.all, Filling, Given (Formal_Position),
                           Promoted, Site_Of (Of_Tree, Argument));
                     end if;
                  end;
               end if;

               if Has_Runtime_After (Written) then
                  --  Erased dispatch retains every nonself carrier shape.
                  --  Saving just its usize address loses that proof on reload.
                  Saved (Formal_Position) :=
                    (if Parameter.Convention = Syn.Inout_Convention
                     then IR.Add_Address_Slot
                       (Unit.all, Filling, Neutral_Result_Part (Parameter),
                        Site_Of (Of_Tree, Argument))
                     elsif Erased_Self
                       and then Parameter.Kind in
                         Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
                           | Ty.Any_Value
                     then IR.Add_Address_Slot
                       (Unit.all, Filling, Neutral_Result_Part (Parameter),
                        Site_Of (Of_Tree, Argument))
                     elsif IR.Signature_Uses_C_ABI (Unit.all, Signature)
                        and then Parameter.Kind = Ty.Aggregate
                     then IR.Add_Address_Slot
                       (Unit.all, Filling, Neutral_Body (Parameter.Nominal),
                        Site_Of (Of_Tree, Argument))
                     else IR.Add_Slot
                      (Unit.all, Filling,
                       Ty.Scalar_Name (IR.Result_Of
                         (Unit.all, Filling, Given (Formal_Position))),
                       Res.No_Declaration, Site_Of (Of_Tree, Argument),
                       Pointee => IR.Pointee_Of
                         (Unit.all, Filling, Given (Formal_Position)),
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
                          else IR.No_Atom_Set)));
                  IR.Emit_Store
                    (Unit.all, Filling, Saved (Formal_Position),
                     Given (Formal_Position), Site_Of (Of_Tree, Argument));
               end if;
            end;
            <<Next_Runtime_Argument>>
            null;
         end loop;

         --  D192: omission constructs three ordinary u32 fields. No text
         --  or per-site module datum exists. Forwarding is filled above.
         for Which in Parameter_Offset + 1 .. Count loop
            if Landin.Checking.Nth_Signature_Parameter
              (Types.all, Source_Signature, Which).Caller
              and then Given (Which) = IR.No_Value
            then
               declare
                  Id : constant Landin.Checking.Nominal_Type_Id :=
                    Landin.Checking.Nth_Signature_Parameter
                      (Types.all, Source_Signature, Which).Nominal;
                  Temporary : constant IR.Slot_Id := IR.Add_Aggregate_Slot
                    (Unit.all, Filling, Res.No_Declaration, Site,
                     Nominal_For (Id));
                  Source_Id : constant Landin.Source.Source_Id :=
                    Syn.Source_Of (Of_Tree);
                  Position : constant Landin.Source.Position :=
                    Landin.Source.Position_Of
                      (Source (Context, Source_Id),
                       Syn.Anchor (Of_Tree, Node).First);
                  Fields : constant array (1 .. 3) of Ty.Magnitude :=
                    [Ty.Magnitude (Source_Id),
                     Ty.Magnitude (Position.Line),
                     Ty.Magnitude (Position.Column)];
               begin
                  IR.Note_Caller_Source (Unit.all, Source_Id);
                  for Field in Fields'Range loop
                     Add_Stored_Field (Id, Field, Slot => Temporary);
                     declare
                        Value : constant IR.Value_Id := IR.Emit_Number
                          (Unit.all, Filling, Ty.U32,
                           Fields (Field), False, Site);
                     begin
                        IR.Emit_Store_Slot_Field
                          (Unit.all, Filling, Temporary,
                           IR.Part_Position (Field), Value, Site);
                     end;
                  end loop;
                  Given (Which) := IR.Emit_Storage_Address
                    (Unit.all, Filling,
                     (Kind => IR.Frame_Slot, Slot => Temporary), Site);
               end;
            end if;
         end loop;

         --  Every argument must precede the call, because Add_Argument
         --  requires the call to remain the last instruction emitted.
         for Which in 1 .. Actual_Count loop
            if Saved (Which) /= IR.No_Slot then
               Given (Which) :=
                 IR.Emit_Load (Unit.all, Filling, Saved (Which), Site);
            end if;
         end loop;

         if Returns_Stored then
            if Destination = IR.No_Slot then
               raise Landin.Compiler_Defect with
                 "a stored call result has no logical destination";
            end if;
            Hidden := IR.Emit_Storage_Address
              (Unit.all, Filling,
               (Kind => IR.Frame_Slot, Slot => Destination), Site,
               Field => Destination_Field,
               Nested => Destination_Steps);
         end if;

         if Indirect and then not Erased_Self then
            Callee_Value :=
              IR.Emit_Load (Unit.all, Filling, Callee_Saved, Site);
         end if;

         for Which in 1 .. Evidence_Count loop
            declare
               Source : constant Landin.Checking.Conformance_Id :=
                 Landin.Checking.Nth_Routine_Evidence
                   (Types.all, Generic_Target, Which);
            begin
               Evidence_Arguments (Which) := IR.Emit_Evidence_Address
                 (Unit.all, Filling, Evidence_For (Source), Site);
            end;
         end loop;

         if Erased_Self then
            declare
               Receiver : constant IR.Value_Id := IR.Emit_Storage_Address
                 (Unit.all, Filling,
                  (Kind => IR.Frame_Slot, Slot => Receiver_Saved), Site);
            begin
               Callee_Value := IR.Emit_Erased_Evidence_Function
                 (Unit.all, Filling, Receiver, Dispatch_Evidence,
                  Positive (Dispatch_Entry), Site);
               Given (1) := IR.Emit_Evidence_Self
                 (Unit.all, Filling, Callee_Value, Site);
            end;
         end if;

         Made :=
           (if Indirect
            then IR.Emit_Indirect_Call
              (Unit.all, Filling, Signature,
               (if Returns_Stored then Ty.No_Value
                elsif Type_At (Of_Tree, Node)
                  in Ty.Function_Value | Ty.Pointer_Value
                then Ty.Usize
                elsif Type_At (Of_Tree, Node) = Ty.Atom_Value
                then Ty.U32 else Type_At (Of_Tree, Node)),
               Site, Failure => Failure_Slot)
            else IR.Emit_Call
              (Unit.all, Filling, Target,
               (if Returns_Stored then Ty.No_Value
                elsif Type_At (Of_Tree, Node)
                  in Ty.Function_Value | Ty.Pointer_Value
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

         for Which in 1 .. Evidence_Count loop
            IR.Add_Argument
              (Unit.all, Filling, Made, Evidence_Arguments (Which));
         end loop;

         for Which in 1 .. Actual_Count loop
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
      --  Slice carriers [0570]
      ------------------------------------------------------------

      function Slice_Shape
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Field_Shape
      is
         Descriptor : constant Landin.Checking.Reference_Descriptor :=
           Landin.Checking.Descriptor_Of
             (Types.all,
              Landin.Checking.Reference_Of (Types.all, Of_Tree, Node));
      begin
         if Descriptor.Referent in Ty.Scalar_Name then
            return
              (Kind => IR.Scalar_Field_Shape,
               Element => Ty.Scalar_Name (Descriptor.Referent),
               Length => 1, others => <>);
         elsif Descriptor.Referent
           in Ty.Pointer_Value | Ty.Function_Value
         then
            return
              (Kind => IR.Scalar_Field_Shape, Element => Ty.Usize,
               Pointee =>
                 (if Descriptor.Referent = Ty.Pointer_Value
                  then Pointee_For (Descriptor.Reference) else IR.No_Pointee),
               Signature =>
                 (if Descriptor.Referent = Ty.Function_Value
                  then Signature_For (Descriptor.Signature)
                  else IR.No_Signature),
               others => <>);
         elsif Descriptor.Referent = Ty.Atom_Value then
            return
              (Kind => IR.Scalar_Field_Shape, Element => Ty.U32,
               Atoms => Atom_Set_For (Descriptor.Atoms), others => <>);
         elsif Descriptor.Referent = Ty.Aggregate then
            return Neutral_Body (Descriptor.Nominal);
         elsif Descriptor.Referent = Ty.Fixed_Array then
            declare
               Element : constant IR.Field_Shape := Neutral_Element
                 ((Kind => Ty.Fixed_Array,
                   Element => Descriptor.Element,
                   Nominal => Descriptor.Element_Nominal,
                   Element_Shape => Descriptor.Element_Shape, others => <>));
            begin
               return IR.Make_Array_Shape
                 (Unit.all, IR.Element_Total (Descriptor.Length), Element);
            end;
         elsif Descriptor.Referent
           in Ty.Slice_Value | Ty.Any_Value
         then
            return
              (Kind => IR.Array_Field_Shape, Element => Ty.Usize,
               Length => 2, others => <>);
         end if;
         raise Landin.Compiler_Defect with
           "a malformed slice element descriptor reached lowering";
      end Slice_Shape;

      function Load_Slice_Component
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Position : IR.Part_Position) return IR.Value_Id
      is
         Place : constant Stored_Place :=
           Lower_Stored_Place (Of_Tree, Node, Scope);
         Field : IR.Part_Position;
         Steps : Stored_Path_Vectors.Vector := Place.Steps;
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Descriptor_Shape : constant IR.Field_Shape :=
           (Kind => IR.Array_Field_Shape, Element => Ty.Usize,
            Length => 2, others => <>);
      begin
         if Place.Place.Kind /= IR.Runtime_Address
           and then (Place.Base /= 0 or else Place.Steps.Is_Empty)
         then
            if Place.Base = 0 then
               Field := Position;
            else
               Field := IR.Part_Position (Place.Base);
               Steps.Append
                 (IR.Path_Step'(Field => Position, Case_Index => 0));
            end if;
            declare
               Made : IR.Path_Step_Array (1 .. Natural (Steps.Length));
            begin
               for Index in Made'Range loop
                  Made (Index) := Steps (Index);
               end loop;
               case Place.Place.Kind is
                  when IR.Module_Datum =>
                     return IR.Emit_Load_Field
                       (Unit.all, Filling, Place.Place.Datum, Field,
                        Ty.Usize, Site, Nested => Made);
                  when IR.Frame_Slot =>
                     return IR.Emit_Load_Slot_Field
                       (Unit.all, Filling, Place.Place.Slot, Field,
                        Ty.Usize, Site, Nested => Made);
                  when IR.Runtime_Address =>
                     raise Landin.Compiler_Defect with
                       "a runtime slice descriptor bypassed its address";
               end case;
            end;
         end if;

         declare
            --  D178: the descriptor can itself be an array element.  First
            --  retain the complete path to those two words, then address
            --  the selected word below it; prepending Position would walk
            --  the descriptor before its containing array element.
            Descriptor : constant IR.Storage :=
              Addressed_Storage (Place, Descriptor_Shape, Site);
            Address : constant IR.Value_Id :=
              IR.Emit_Place_Address
                (Unit.all, Filling, Descriptor, Site,
                 Field => Natural (Position));
         begin
            return IR.Emit_Load_Indirect
              (Unit.all, Filling, Address, Ty.Usize, Site);
         end;
      end Load_Slice_Component;

      function Lower_Slice
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return Slice_Values
      is
      begin
         if Syn.Kind (Of_Tree, Node)
              in Syn.Inclusive_Slice | Syn.Half_Open_Slice
                 | Syn.Empty_Slice_Literal | Syn.Text_Literal
                 | Syn.Raw_Literal | Syn.Call | Syn.Labeled_Application
                 | Syn.Try_Expression | Syn.If_Statement
                 | Syn.Match_Statement | Syn.Bare_Block
                 | Syn.Loop_Statement | Syn.While_Statement
                 | Syn.For_Statement
           or else Is_Utf8_Index (Of_Tree, Node)
         then
            declare
               --  D179: a collection source may be a computed slice.  Fill
               --  one temporary before loading either carrier cell, so a
               --  call or control expression is evaluated exactly once.
               Temporary : constant IR.Slot_Id := IR.Add_Array_Slot
                 (Unit.all, Filling, Ty.Usize, 2, Res.No_Declaration,
                  Site_Of (Of_Tree, Node));
            begin
               Lower_Slice_Into (Of_Tree, Node, Scope, Temporary);
               if Current = IR.No_Block then
                  return (Base => IR.No_Value, Length => IR.No_Value);
               end if;
               return
                 (Base => IR.Emit_Load_Slot_Field
                    (Unit.all, Filling, Temporary, 1, Ty.Usize,
                     Site_Of (Of_Tree, Node)),
                  Length => IR.Emit_Load_Slot_Field
                    (Unit.all, Filling, Temporary, 2, Ty.Usize,
                     Site_Of (Of_Tree, Node)));
            end;
         end if;
         return
           (Base => Load_Slice_Component
              (Of_Tree, Node, Scope, 1),
            Length => Load_Slice_Component
              (Of_Tree, Node, Scope, 2));
      end Lower_Slice;

      procedure Lower_Slice_Into
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Destination : IR.Slot_Id)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);

         function Text_Unit_Width
           (Base, Total, Offset : IR.Value_Id;
            View                : Ty.Text_View;
            Allow_End           : Boolean) return IR.Value_Id;
         procedure Lower_Utf8_Index;
         procedure Lower_Text_Conversion
           (Conversion : Landin.Checking.Text_Conversion_Kind);

         procedure Lower_Text_Conversion
           (Conversion : Landin.Checking.Text_Conversion_Kind)
         is
            Written : constant Syn.Node_Id :=
              Syn.Nth_Argument (Of_Tree, Node, 1);
            Argument : constant Syn.Node_Id :=
              (if Syn.Kind (Of_Tree, Written) = Syn.Call_Argument
               then Syn.Argument_RHS (Of_Tree, Written)
               else Written);
            Base_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Length_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);

            procedure Store_Result;
            procedure Validate_Utf8;
            procedure Scan_C_String;

            procedure Store_Result is
            begin
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 1,
                  IR.Emit_Load (Unit.all, Filling, Base_Slot, Site), Site);
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 2,
                  IR.Emit_Load (Unit.all, Filling, Length_Slot, Site), Site);
            end Store_Result;

            --  A conversion into utf8 is the dynamic edge which establishes
            --  D181's value invariant.  The shortest-form ranges also
            --  exclude surrogates and codepoints above U+10FFFF.
            procedure Validate_Utf8 is
               Cursor_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Lead_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
               Head : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Inspect : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               One : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Non_ASCII : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Class_Two : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Two : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Two_Advance : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Class_Three : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Three : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Three_Not_E0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Three_E0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Three_ED : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Three_Normal : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Three_Tail : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Three_Advance : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Four_Not_F0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_F0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_F4 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_Normal : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_Tail_One : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_Tail_Two : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_Advance : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Four_Complete : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Invalid : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Done : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);

               function Byte_At (Relative : Ty.Magnitude) return IR.Value_Id;
               function Lead_Is
                 (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                  return IR.Value_Id;
               procedure Require_Range
                 (Value : IR.Value_Id;
                  Lower, Upper : Ty.Magnitude;
                  Success : IR.Block_Id);
               procedure Advance (Amount : Ty.Magnitude);

               function Byte_At (Relative : Ty.Magnitude) return IR.Value_Id
               is
                  Position : IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Cursor_Slot, Site);
                  Address : IR.Value_Id;
               begin
                  if Relative /= 0 then
                     Position := IR.Emit_Binary
                       (Unit.all, Filling, IR.Add, Position,
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.Usize, Relative, False,
                           Site),
                        Ty.Usize, Site);
                  end if;
                  Address := IR.Emit_Slice_Address
                    (Unit.all, Filling,
                     IR.Emit_Load (Unit.all, Filling, Base_Slot, Site),
                     IR.Emit_Load (Unit.all, Filling, Length_Slot, Site),
                     Position, Position, Slice_Shape (Of_Tree, Node), True,
                     Site, Required => True);
                  return IR.Emit_Load_Indirect
                    (Unit.all, Filling, Address, Ty.U8, Site);
               end Byte_At;

               function Lead_Is
                 (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                  return IR.Value_Id
               is
               begin
                  return IR.Emit_Binary
                    (Unit.all, Filling, Op,
                     IR.Emit_Load (Unit.all, Filling, Lead_Slot, Site),
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.U8, Value, False, Site),
                     Ty.Bool, Site);
               end Lead_Is;

               procedure Require_Range
                 (Value : IR.Value_Id;
                  Lower, Upper : Ty.Magnitude;
                  Success : IR.Block_Id)
               is
                  Saved : constant IR.Slot_Id := IR.Add_Slot
                    (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
                  Test_Upper : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Scope);
               begin
                  IR.Emit_Store (Unit.all, Filling, Saved, Value, Site);
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Greater_Or_Equal,
                        IR.Emit_Load (Unit.all, Filling, Saved, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U8, Lower, False, Site),
                        Ty.Bool, Site),
                     Test_Upper, Invalid, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
                  Open (Test_Upper);
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Less_Or_Equal,
                        IR.Emit_Load (Unit.all, Filling, Saved, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U8, Upper, False, Site),
                        Ty.Bool, Site),
                     Success, Invalid, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end Require_Range;

               procedure Advance (Amount : Ty.Magnitude) is
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Cursor_Slot,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Add,
                        IR.Emit_Load
                          (Unit.all, Filling, Cursor_Slot, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.Usize, Amount, False, Site),
                        Ty.Usize, Site),
                     Site);
                  Close_With_Jump (Head, Site);
               end Advance;
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Cursor_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
               Close_With_Jump (Head, Site);

               Open (Head);
               IR.Emit_Branch
                 (Unit.all, Filling,
                  IR.Emit_Binary
                    (Unit.all, Filling, IR.Equal_To,
                     IR.Emit_Load (Unit.all, Filling, Cursor_Slot, Site),
                     IR.Emit_Load (Unit.all, Filling, Length_Slot, Site),
                     Ty.Bool, Site),
                  Done, Inspect, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Inspect);
               IR.Emit_Store
                 (Unit.all, Filling, Lead_Slot, Byte_At (0), Site);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#80#),
                  One, Non_ASCII, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (One);
               Advance (1);

               Open (Non_ASCII);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#C2#),
                  Invalid, Class_Two, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Class_Two);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#E0#),
                  Two, Class_Three, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Two);
               Require_Range
                 (Byte_At (1), 16#80#, 16#BF#, Two_Advance);
               Open (Two_Advance);
               Advance (2);

               Open (Class_Three);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#F0#),
                  Three, Four, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Three);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#E0#),
                  Three_E0, Three_Not_E0, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Three_E0);
               Require_Range
                 (Byte_At (1), 16#A0#, 16#BF#, Three_Tail);

               Open (Three_Not_E0);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#ED#),
                  Three_ED, Three_Normal, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Three_ED);
               Require_Range
                 (Byte_At (1), 16#80#, 16#9F#, Three_Tail);

               Open (Three_Normal);
               Require_Range
                 (Byte_At (1), 16#80#, 16#BF#, Three_Tail);

               Open (Three_Tail);
               Require_Range
                 (Byte_At (2), 16#80#, 16#BF#, Three_Advance);
               Open (Three_Advance);
               Advance (3);

               Open (Four);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Or_Equal, 16#F4#),
                  Four_Not_F0, Invalid, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Four_Not_F0);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#F0#),
                  Four_F0, Four_Tail_One, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Four_Tail_One);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#F4#),
                  Four_F4, Four_Normal, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Four_F0);
               Require_Range
                 (Byte_At (1), 16#90#, 16#BF#, Four_Tail_Two);
               Open (Four_F4);
               Require_Range
                 (Byte_At (1), 16#80#, 16#8F#, Four_Tail_Two);
               Open (Four_Normal);
               Require_Range
                 (Byte_At (1), 16#80#, 16#BF#, Four_Tail_Two);

               Open (Four_Tail_Two);
               Require_Range
                 (Byte_At (2), 16#80#, 16#BF#, Four_Advance);
               Open (Four_Advance);
               Require_Range
                 (Byte_At (3), 16#80#, 16#BF#, Four_Complete);
               Open (Four_Complete);
               Advance (4);

               Open (Invalid);
               declare
                  Traps : constant IR.Value_Id := IR.Emit_Range_Check
                    (Unit.all, Filling,
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.U8, 1, False, Site),
                     Ty.U8, 0, 0, Site);
               begin
                  pragma Unreferenced (Traps);
                  Close_With_Jump (Done, Site);
               end;

               Open (Done);
               Store_Result;
            end Validate_Utf8;

            --  cstring's extent is exactly the accessible prefix before the
            --  first NUL.  This observes the terminator and never asks for a
            --  byte after it; encoding is deliberately not inspected.
            procedure Scan_C_String is
               Cursor_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Head : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Advance : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Scope);
               Done : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Cursor_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
               Close_With_Jump (Head, Site);
               Open (Head);
               declare
                  Position : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Cursor_Slot, Site);
                  Address : constant IR.Value_Id := IR.Emit_Binary
                    (Unit.all, Filling, IR.Add,
                     IR.Emit_Load (Unit.all, Filling, Base_Slot, Site),
                     Position, Ty.Usize, Site);
                  Byte : constant IR.Value_Id := IR.Emit_Load_Indirect
                    (Unit.all, Filling, Address, Ty.U8, Site);
               begin
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Equal_To, Byte,
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U8, 0, False, Site),
                        Ty.Bool, Site),
                     Done, Advance, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end;
               Open (Advance);
               IR.Emit_Store
                 (Unit.all, Filling, Cursor_Slot,
                  IR.Emit_Binary
                    (Unit.all, Filling, IR.Add,
                     IR.Emit_Load (Unit.all, Filling, Cursor_Slot, Site),
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.Usize, 1, False, Site),
                     Ty.Usize, Site), Site);
               Close_With_Jump (Head, Site);
               Open (Done);
               IR.Emit_Store
                 (Unit.all, Filling, Length_Slot,
                  IR.Emit_Load (Unit.all, Filling, Cursor_Slot, Site), Site);
            end Scan_C_String;
         begin
            if Conversion in Landin.Checking.Bytes_To_Utf8
                              | Landin.Checking.Utf8_To_Bytes
            then
               declare
                  Source : constant Slice_Values :=
                    Lower_Slice (Of_Tree, Argument, Scope);
               begin
                  if Current = IR.No_Block then
                     return;
                  end if;
                  IR.Emit_Store
                    (Unit.all, Filling, Base_Slot, Source.Base, Site);
                  IR.Emit_Store
                    (Unit.all, Filling, Length_Slot, Source.Length, Site);
               end;
            else
               declare
                  Source : constant IR.Value_Id :=
                    Lower_Expression (Of_Tree, Argument, Scope);
               begin
                  if Current = IR.No_Block then
                     return;
                  end if;
                  IR.Emit_Store
                    (Unit.all, Filling, Base_Slot, Source, Site);
               end;
               Scan_C_String;
            end if;

            if Conversion in Landin.Checking.Bytes_To_Utf8
                              | Landin.Checking.C_String_To_Utf8
            then
               Validate_Utf8;
            else
               Store_Result;
            end if;
         end Lower_Text_Conversion;

         --  D183: a text range is still represented by a base/length pair,
         --  but each endpoint must preserve the encoded scalar boundary.
         --  The returned width is used only by the inclusive form, whose
         --  written upper endpoint names the first code unit of its final
         --  scalar rather than the final code unit of that scalar.
         function Text_Unit_Width
           (Base, Total, Offset : IR.Value_Id;
            View                : Ty.Text_View;
            Allow_End           : Boolean) return IR.Value_Id
         is
            Base_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Total_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Offset_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Width_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Inspect : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
            Invalid : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
            At_End : constant IR.Block_Id :=
              (if Allow_End then Fresh (Of_Tree, Node, Scope) else Invalid);
            Join : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);

            procedure Store_Width (Value : Ty.Magnitude);

            procedure Store_Width (Value : Ty.Magnitude) is
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Width_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, Value, False, Site),
                  Site);
               Close_With_Jump (Join, Site);
            end Store_Width;
         begin
            IR.Emit_Store (Unit.all, Filling, Base_Slot, Base, Site);
            IR.Emit_Store (Unit.all, Filling, Total_Slot, Total, Site);
            IR.Emit_Store (Unit.all, Filling, Offset_Slot, Offset, Site);
            IR.Emit_Branch
              (Unit.all, Filling,
               IR.Emit_Binary
                 (Unit.all, Filling, IR.Equal_To, Offset, Total,
                  Ty.Bool, Site),
               (if Allow_End then At_End else Invalid), Inspect, Site);
            IR.Leave_Block (Unit.all, Filling);
            Current := IR.No_Block;

            if Allow_End then
               Open (At_End);
               Store_Width (0);
            end if;

            Open (Inspect);
            declare
               Saved_Base : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Base_Slot, Site);
               Saved_Total : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Total_Slot, Site);
               Saved_Offset : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Offset_Slot, Site);
               Address : constant IR.Value_Id := IR.Emit_Slice_Address
                 (Unit.all, Filling, Saved_Base, Saved_Total,
                  Saved_Offset, Saved_Offset, Slice_Shape (Of_Tree, Node),
                  True, Site, Required => True);
               Code_Unit : constant IR.Value_Id := IR.Emit_Load_Indirect
                 (Unit.all, Filling, Address,
                  (if View = Ty.Utf8_View then Ty.U8 else Ty.U16), Site);
            begin
               if View = Ty.Utf8_View then
                  declare
                     Unit_Slot : constant IR.Slot_Id := IR.Add_Slot
                       (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
                     Non_ASCII : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Test_Two : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Test_Three : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Test_Four : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     One_Byte : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Two_Bytes : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Three_Bytes : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Four_Bytes : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);

                     function Unit_Is
                       (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                        return IR.Value_Id;

                     function Unit_Is
                       (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                        return IR.Value_Id
                     is
                     begin
                        return IR.Emit_Binary
                          (Unit.all, Filling, Op,
                           IR.Emit_Load
                             (Unit.all, Filling, Unit_Slot, Site),
                           IR.Emit_Number
                             (Unit.all, Filling, Ty.U8, Value, False, Site),
                           Ty.Bool, Site);
                     end Unit_Is;
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Unit_Slot, Code_Unit, Site);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Than, 16#80#),
                        One_Byte, Non_ASCII, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Non_ASCII);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Than, 16#C2#),
                        Invalid, Test_Two, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Test_Two);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Than, 16#E0#),
                        Two_Bytes, Test_Three, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Test_Three);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Than, 16#F0#),
                        Three_Bytes, Test_Four, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Test_Four);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Or_Equal, 16#F4#),
                        Four_Bytes, Invalid, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (One_Byte);
                     Store_Width (1);
                     Open (Two_Bytes);
                     Store_Width (2);
                     Open (Three_Bytes);
                     Store_Width (3);
                     Open (Four_Bytes);
                     Store_Width (4);
                  end;
               else
                  declare
                     Unit_Slot : constant IR.Slot_Id := IR.Add_Slot
                       (Unit.all, Filling, Ty.U16, Res.No_Declaration, Site);
                     Test_High : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Test_Low : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     One_Unit : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Two_Units : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);

                     function Unit_Is
                       (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                        return IR.Value_Id;

                     function Unit_Is
                       (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                        return IR.Value_Id
                     is
                     begin
                        return IR.Emit_Binary
                          (Unit.all, Filling, Op,
                           IR.Emit_Load
                             (Unit.all, Filling, Unit_Slot, Site),
                           IR.Emit_Number
                             (Unit.all, Filling, Ty.U16, Value, False, Site),
                           Ty.Bool, Site);
                     end Unit_Is;
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Unit_Slot, Code_Unit, Site);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Than, 16#D800#),
                        One_Unit, Test_High, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Test_High);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Than, 16#DC00#),
                        Two_Units, Test_Low, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Test_Low);
                     IR.Emit_Branch
                       (Unit.all, Filling,
                        Unit_Is (IR.Less_Or_Equal, 16#DFFF#),
                        Invalid, One_Unit, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (One_Unit);
                     Store_Width (1);
                     Open (Two_Units);
                     Store_Width (2);
                  end;
               end if;
            end;

            Open (Invalid);
            declare
               Saved_Base : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Base_Slot, Site);
               Saved_Total : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Total_Slot, Site);
               Traps : constant IR.Value_Id := IR.Emit_Slice_Address
                 (Unit.all, Filling, Saved_Base, Saved_Total,
                  Saved_Total, Saved_Total, Slice_Shape (Of_Tree, Node),
                  True, Site, Required => True);
            begin
               pragma Unreferenced (Traps);
               Store_Width (0);
            end;

            Open (Join);
            return IR.Emit_Load (Unit.all, Filling, Width_Slot, Site);
         end Text_Unit_Width;

         procedure Lower_Utf8_Index is
            From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
            Where : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
            Base_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Length_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
            Offset_Slot : constant IR.Slot_Id := IR.Add_Slot
              (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);

            function Byte_At (Offset : IR.Value_Id) return IR.Value_Id;
            function Decode_Width (Lead : IR.Value_Id) return IR.Value_Id;
            function Lower_Position_Offset return IR.Value_Id;
            procedure Store_Codepoint;

            function Byte_At (Offset : IR.Value_Id) return IR.Value_Id
            is
               Base : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Base_Slot, Site);
               Length : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Length_Slot, Site);
               Address : constant IR.Value_Id := IR.Emit_Slice_Address
                 (Unit.all, Filling, Base, Length, Offset, Offset,
                  Slice_Shape (Of_Tree, Node), True, Site,
                  Required => True);
            begin
               return IR.Emit_Load_Indirect
                 (Unit.all, Filling, Address, Ty.U8, Site);
            end Byte_At;

            --  The source has utf8 identity, so a valid position sees one of
            --  the four leading-byte classes.  A continuation-byte position
            --  is not a codepoint boundary; route it through the existing
            --  checked slice-address primitive so the ordinary bounds trap
            --  remains the one runtime failure mechanism.
            function Decode_Width (Lead : IR.Value_Id) return IR.Value_Id
            is
               Lead_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
               Width_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Non_ASCII : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Test_Two : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Test_Three : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Test_Four : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               One_Byte : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Two_Bytes : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Three_Bytes : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Four_Bytes : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Invalid : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Join : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);

               procedure Store_Width (Value : Ty.Magnitude);
               function Lead_Is
                 (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                  return IR.Value_Id;

               procedure Store_Width (Value : Ty.Magnitude) is
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Width_Slot,
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.Usize, Value, False, Site),
                     Site);
                  Close_With_Jump (Join, Site);
               end Store_Width;

               function Lead_Is
                 (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                  return IR.Value_Id
               is
                  Held : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Lead_Slot, Site);
                  Limit : constant IR.Value_Id := IR.Emit_Number
                    (Unit.all, Filling, Ty.U8, Value, False, Site);
               begin
                  return IR.Emit_Binary
                    (Unit.all, Filling, Op, Held, Limit, Ty.Bool, Site);
               end Lead_Is;
            begin
               IR.Emit_Store (Unit.all, Filling, Lead_Slot, Lead, Site);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#80#),
                  One_Byte, Non_ASCII, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Non_ASCII);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#C2#),
                  Invalid, Test_Two, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Test_Two);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#E0#),
                  Two_Bytes, Test_Three, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Test_Three);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#F0#),
                  Three_Bytes, Test_Four, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Test_Four);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Or_Equal, 16#F4#),
                  Four_Bytes, Invalid, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (One_Byte);
               Store_Width (1);
               Open (Two_Bytes);
               Store_Width (2);
               Open (Three_Bytes);
               Store_Width (3);
               Open (Four_Bytes);
               Store_Width (4);

               Open (Invalid);
               declare
                  Base : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Base_Slot, Site);
                  Length : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Length_Slot, Site);
                  Traps : constant IR.Value_Id := IR.Emit_Slice_Address
                    (Unit.all, Filling, Base, Length, Length, Length,
                     Slice_Shape (Of_Tree, Node), True, Site,
                     Required => True);
               begin
                  pragma Unreferenced (Traps);
                  Store_Width (1);
               end;

               Open (Join);
               return IR.Emit_Load (Unit.all, Filling, Width_Slot, Site);
            end Decode_Width;

            function Lower_Position_Offset return IR.Value_Id is
            begin
               if Syn.Kind (Of_Tree, Where)
                    in Syn.Name_Reference | Syn.Member_Selection
                       | Syn.Element_Index
               then
                  declare
                     Position : constant Stored_Place :=
                       Lower_Stored_Place (Of_Tree, Where, Scope);
                     Nominal : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of
                         (Types.all, Of_Tree, Where);
                     Storage : constant IR.Storage := Addressed_Storage
                       (Position, Neutral_Body (Nominal), Site);
                     Address : constant IR.Value_Id := IR.Emit_Place_Address
                       (Unit.all, Filling, Storage, Site, Field => 1);
                  begin
                     return IR.Emit_Load_Indirect
                       (Unit.all, Filling, Address, Ty.Usize, Site);
                  end;
               elsif Syn.Kind (Of_Tree, Where)
                 in Syn.Call | Syn.Labeled_Application | Syn.Try_Expression
                    | Syn.If_Statement | Syn.Match_Statement
                    | Syn.Bare_Block | Syn.Loop_Statement
                    | Syn.While_Statement | Syn.For_Statement
               then
                  declare
                     Temporary : constant IR.Slot_Id :=
                       Add_Value_Temporary (Of_Tree, Where);
                  begin
                     Lower_Stored_Expression
                       (Of_Tree, Where, Scope, Temporary);
                     if Current = IR.No_Block then
                        return IR.No_Value;
                     end if;
                     return IR.Emit_Load_Slot_Field
                       (Unit.all, Filling, Temporary, 1, Ty.Usize, Site);
                  end;
               end if;
               raise Landin.Compiler_Defect with
                 "a checked text position has no lowering path";
            end Lower_Position_Offset;

            procedure Store_Codepoint is
               Before : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Offset_Slot, Site);
               Lead : constant IR.Value_Id := Byte_At (Before);
               Width : constant IR.Value_Id := Decode_Width (Lead);
               Offset : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Offset_Slot, Site);
               Upper : constant IR.Value_Id := IR.Emit_Binary
                 (Unit.all, Filling, IR.Add, Offset, Width, Ty.Usize, Site);
               Base : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Base_Slot, Site);
               Length : constant IR.Value_Id := IR.Emit_Load
                 (Unit.all, Filling, Length_Slot, Site);
               Address : constant IR.Value_Id := IR.Emit_Slice_Address
                 (Unit.all, Filling, Base, Length, Offset, Upper,
                  Slice_Shape (Of_Tree, Node), False, Site,
                  Required => True);
            begin
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 1, Address, Site);
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 2, Width, Site);
            end Store_Codepoint;

            Parts : constant Slice_Values := Lower_Slice
              (Of_Tree, From, Scope);
         begin
            IR.Emit_Store (Unit.all, Filling, Base_Slot, Parts.Base, Site);
            IR.Emit_Store
              (Unit.all, Filling, Length_Slot, Parts.Length, Site);

            if Type_At (Of_Tree, Where) = Ty.Aggregate then
               declare
                  Offset : constant IR.Value_Id := Lower_Position_Offset;
               begin
                  if Current = IR.No_Block then
                     return;
                  end if;
                  IR.Emit_Store
                    (Unit.all, Filling, Offset_Slot, Offset, Site);
                  Store_Codepoint;
               end;
               return;
            end if;

            declare
               Wanted_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site);
               Count_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site);
               Wanted : constant IR.Value_Id := Lower_Expression
                 (Of_Tree, Where, Scope);
               Test : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Advance : constant IR.Block_Id := Fresh
                 (Of_Tree, Node, Scope);
               Found : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
            begin
               if Current = IR.No_Block then
                  return;
               end if;
               IR.Emit_Store (Unit.all, Filling, Wanted_Slot, Wanted, Site);
               IR.Emit_Store
                 (Unit.all, Filling, Count_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.U32, 0, False, Site), Site);
               IR.Emit_Store
                 (Unit.all, Filling, Offset_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
               Close_With_Jump (Test, Site);

               Open (Test);
               declare
                  Count : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Count_Slot, Site);
                  Goal : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Wanted_Slot, Site);
                  Ready : constant IR.Value_Id := IR.Emit_Binary
                    (Unit.all, Filling, IR.Equal_To, Count, Goal,
                     Ty.Bool, Site);
               begin
                  IR.Emit_Branch
                    (Unit.all, Filling, Ready, Found, Advance, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end;

               Open (Advance);
               declare
                  Before : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Offset_Slot, Site);
                  Lead : constant IR.Value_Id := Byte_At (Before);
                  Width : constant IR.Value_Id := Decode_Width (Lead);
                  Offset : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Offset_Slot, Site);
                  Count : constant IR.Value_Id := IR.Emit_Load
                    (Unit.all, Filling, Count_Slot, Site);
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Offset_Slot,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Add, Offset, Width,
                        Ty.Usize, Site), Site);
                  IR.Emit_Store
                    (Unit.all, Filling, Count_Slot,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Add, Count,
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U32, 1, False, Site),
                        Ty.U32, Site), Site);
                  Close_With_Jump (Test, Site);
               end;

               Open (Found);
               Store_Codepoint;
            end;
         end Lower_Utf8_Index;
      begin
         declare
            Conversion : constant Landin.Checking.Text_Conversion_Kind :=
              Landin.Checking.Text_Conversion_Of
                (Types.all, Of_Tree, Node);
         begin
            if Conversion /= Landin.Checking.No_Text_Conversion then
               Lower_Text_Conversion (Conversion);
               return;
            end if;
         end;

         if Syn.Kind (Of_Tree, Node)
           in Syn.Call | Syn.Labeled_Application | Syn.Try_Expression
              | Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
              | Syn.Loop_Statement | Syn.While_Statement
              | Syn.For_Statement
         then
            Lower_Stored_Expression
              (Of_Tree, Node, Scope, Destination);
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Any_Construction then
            declare
               Data : constant IR.Value_Id := Lower_Expression
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope);
               Evidence : constant Landin.Checking.Conformance_Id :=
                 Landin.Checking.Evidence_Of (Types.all, Of_Tree, Node);
               Table : IR.Value_Id;
            begin
               if Evidence = Landin.Checking.No_Conformance then
                  raise Landin.Compiler_Defect with
                    "an any construction has no selected evidence";
               end if;
               Table := IR.Emit_Evidence_Address
                 (Unit.all, Filling, Any_Evidence_For (Evidence), Site);
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 1, Data, Site);
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 2, Table, Site);
            end;
            return;
         end if;

         if Is_Utf8_Index (Of_Tree, Node) then
            Lower_Utf8_Index;
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Empty_Slice_Literal then
            declare
               Base : constant IR.Value_Id := IR.Emit_Empty_Slice_Base
                 (Unit.all, Filling, Slice_Shape (Of_Tree, Node), Site);
               Length : constant IR.Value_Id := IR.Emit_Number
                 (Unit.all, Filling, Ty.Usize, 0, False, Site);
            begin
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 1, Base, Site);
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 2, Length, Site);
            end;
            return;
         elsif Syn.Kind (Of_Tree, Node)
                 in Syn.Text_Literal | Syn.Raw_Literal
         then
            --  D161/D164: the slice views the shared read-only datum, and
            --  its length leaves the trailing NUL out.
            declare
               Datum : constant IR.Item_Id := Text_Datum (Of_Tree, Node);
               Base : constant IR.Value_Id := IR.Emit_Storage_Address
                 (Unit.all, Filling,
                  (Kind => IR.Module_Datum, Datum => Datum), Site);
               Length : constant IR.Value_Id := IR.Emit_Number
                 (Unit.all, Filling, Ty.Usize,
                  Ty.Magnitude (IR.Array_Length (Unit.all, Datum) - 1),
                  False, Site);
            begin
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 1, Base, Site);
               IR.Emit_Store_Slot_Field
                 (Unit.all, Filling, Destination, 2, Length, Site);
            end;
            return;
         elsif Syn.Kind (Of_Tree, Node)
           in Syn.Inclusive_Slice | Syn.Half_Open_Slice
         then
            declare
               Source : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Descriptor : constant Landin.Checking.Reference_Descriptor :=
                 Landin.Checking.Descriptor_Of
                   (Types.all,
                    Landin.Checking.Reference_Of (Types.all, Of_Tree, Node));
               Is_Text : constant Boolean :=
                 Descriptor.View in Ty.Utf8_View | Ty.Utf16_View;
               Base_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Total_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Saved_Lower : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Saved_Upper : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Saved_Address : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Base : IR.Value_Id;
               Total : IR.Value_Id;
            begin
               if Type_At (Of_Tree, Source) = Ty.Slice_Value then
                  if Is_Text then
                     declare
                        --  D183 retains the complete source carrier before
                        --  either bound runs.  In particular, an indexed
                        --  aggregate field that holds text evaluates its
                        --  own index only once rather than once per word.
                        Temporary : constant IR.Slot_Id := IR.Add_Array_Slot
                          (Unit.all, Filling, Ty.Usize, 2,
                           Res.No_Declaration, Site);
                     begin
                        Lower_Slice_Into
                          (Of_Tree, Source, Scope, Temporary);
                        Base := IR.Emit_Load_Slot_Field
                          (Unit.all, Filling, Temporary, 1, Ty.Usize, Site);
                        Total := IR.Emit_Load_Slot_Field
                          (Unit.all, Filling, Temporary, 2, Ty.Usize, Site);
                     end;
                  else
                     declare
                        Parts : constant Slice_Values :=
                          Lower_Slice (Of_Tree, Source, Scope);
                     begin
                        Base := Parts.Base;
                        Total := Parts.Length;
                     end;
                  end if;
               else
                  declare
                     Place : constant Stored_Place :=
                       Lower_Stored_Place (Of_Tree, Source, Scope);
                  begin
                     Base := IR.Emit_Storage_Address
                       (Unit.all, Filling, Place.Place, Site,
                        Field => Place.Base, Nested => Stored_Steps (Place));
                     Total := IR.Emit_Number
                       (Unit.all, Filling, Ty.Usize,
                        Ty.Magnitude
                          (Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Source)), False, Site);
                  end;
               end if;

               IR.Emit_Store (Unit.all, Filling, Base_Slot, Base, Site);
               IR.Emit_Store (Unit.all, Filling, Total_Slot, Total, Site);

               declare
                  Lower_Value : constant IR.Value_Id := Lower_Expression
                    (Of_Tree, Syn.Slice_Lower (Of_Tree, Node), Scope);
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Saved_Lower, Lower_Value, Site);
                  declare
                     Upper : constant IR.Value_Id := Lower_Expression
                       (Of_Tree, Syn.Slice_Upper (Of_Tree, Node), Scope);
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Saved_Upper, Upper, Site);
                     declare
                        Lower : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Saved_Lower, Site);
                        Kept_Upper : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Saved_Upper, Site);
                        Kept_Base : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Base_Slot, Site);
                        Kept_Total : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Total_Slot, Site);
                        --  D187 never removes a text boundary edge:
                        --  D181's validated view is what makes D184's
                        --  decoder infallible, and a non-boundary `utf8`
                        --  is not a value the type holds.
                        Address : constant IR.Value_Id :=
                          IR.Emit_Slice_Address
                            (Unit.all, Filling, Kept_Base, Kept_Total,
                             Lower, Kept_Upper, Slice_Shape (Of_Tree, Node),
                             Syn.Kind (Of_Tree, Node)
                               = Syn.Inclusive_Slice,
                             Site, Required => Is_Text);
                        End_Offset : IR.Value_Id := IR.No_Value;
                     begin
                        IR.Emit_Store
                          (Unit.all, Filling, Saved_Address, Address, Site);
                        if Is_Text then
                           declare
                              Lower_Width : constant IR.Value_Id :=
                                Text_Unit_Width
                                  (IR.Emit_Load
                                     (Unit.all, Filling, Base_Slot, Site),
                                   IR.Emit_Load
                                     (Unit.all, Filling, Total_Slot, Site),
                                   IR.Emit_Load
                                     (Unit.all, Filling, Saved_Lower, Site),
                                   Ty.Text_View (Descriptor.View),
                                   Syn.Kind (Of_Tree, Node)
                                     = Syn.Half_Open_Slice);
                              pragma Unreferenced (Lower_Width);
                              Upper_Width : constant IR.Value_Id :=
                                Text_Unit_Width
                                  (IR.Emit_Load
                                     (Unit.all, Filling, Base_Slot, Site),
                                   IR.Emit_Load
                                     (Unit.all, Filling, Total_Slot, Site),
                                   IR.Emit_Load
                                     (Unit.all, Filling, Saved_Upper, Site),
                                   Ty.Text_View (Descriptor.View),
                                   Syn.Kind (Of_Tree, Node)
                                     = Syn.Half_Open_Slice);
                           begin
                              if Syn.Kind (Of_Tree, Node)
                                = Syn.Inclusive_Slice
                              then
                                 End_Offset := IR.Emit_Binary
                                   (Unit.all, Filling, IR.Add,
                                    IR.Emit_Load
                                      (Unit.all, Filling, Saved_Upper, Site),
                                    Upper_Width, Ty.Usize, Site);
                              else
                                 End_Offset := IR.Emit_Load
                                   (Unit.all, Filling, Saved_Upper, Site);
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Node)
                          = Syn.Inclusive_Slice
                        then
                           declare
                              One : constant IR.Value_Id := IR.Emit_Number
                                (Unit.all, Filling, Ty.Usize, 1, False, Site);
                           begin
                              End_Offset := IR.Emit_Binary
                                (Unit.all, Filling, IR.Add,
                                 IR.Emit_Load
                                   (Unit.all, Filling, Saved_Upper, Site), One,
                                 Ty.Usize, Site);
                           end;
                        else
                           End_Offset := IR.Emit_Load
                             (Unit.all, Filling, Saved_Upper, Site);
                        end if;
                        declare
                           Difference : constant IR.Value_Id := IR.Emit_Binary
                             (Unit.all, Filling, IR.Subtract,
                              End_Offset,
                              IR.Emit_Load
                                (Unit.all, Filling, Saved_Lower, Site),
                              Ty.Usize, Site);
                        begin
                           IR.Emit_Store_Slot_Field
                             (Unit.all, Filling, Destination, 1,
                              IR.Emit_Load
                                (Unit.all, Filling, Saved_Address, Site),
                              Site);
                           IR.Emit_Store_Slot_Field
                             (Unit.all, Filling, Destination, 2, Difference,
                              Site);
                        end;
                     end;
                  end;
               end;
            end;
            return;
         end if;

         declare
            Source : constant Stored_Place :=
              Lower_Stored_Place (Of_Tree, Node, Scope);
         begin
            IR.Emit_Array_Copy
              (Unit.all, Filling, Source.Place,
               (Kind => IR.Frame_Slot, Slot => Destination), Site,
               Source_Field => Source.Base,
               Source_Nested => Stored_Steps (Source));
         end;
      end Lower_Slice_Into;

      ------------------------------------------------------------
      --  Expressions [1820]
      ------------------------------------------------------------

      function Lower_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Made : constant IR.Value_Id :=
           Lower_Unconstrained (Of_Tree, Node, Scope);
         Owed : constant Landin.Checking.Constraint_Id :=
           Landin.Checking.Owed_Check (Types.all, Of_Tree, Node);
      begin
         if Current /= IR.No_Block and then Made /= IR.No_Value
           and then Type_At (Of_Tree, Node) = Ty.Pointer_Value
         then
            IR.Set_Pointee
              (Unit.all, Filling, Made,
               Pointee_For
                 (Landin.Checking.Reference_Of (Types.all, Of_Tree, Node)));
         end if;
         --  Lower_Unconstrained answers No_Value exactly when it
         --  terminated the flow, and every emission in this file stops
         --  there.  D188's check is no exception: an expression whose every
         --  edge returns leaves no value to hold to the bounds and no
         --  reachable block to hold it in.
         if Owed = Landin.Checking.No_Constraint
           or else Current = IR.No_Block
         then
            return Made;
         end if;

         declare
            Bounds : constant Landin.Checking.Constraint_Descriptor :=
              Landin.Checking.Bounds_Of (Types.all, Owed);
         begin
            return IR.Emit_Range_Check
              (Unit.all, Filling, Made, Bounds.Base,
               Bounds.Lower, Bounds.Upper, Site_Of (Of_Tree, Node));
         end;
      end Lower_Expression;

      function Checked_Update
        (Of_Tree : Syn.Tree;
         Stmt    : Syn.Node_Id;
         Value   : IR.Value_Id) return IR.Value_Id
      is
         Owed : constant Landin.Checking.Constraint_Id :=
           Landin.Checking.Owed_Check (Types.all, Of_Tree, Stmt);
      begin
         if Owed = Landin.Checking.No_Constraint then
            return Value;
         end if;

         declare
            Bounds : constant Landin.Checking.Constraint_Descriptor :=
              Landin.Checking.Bounds_Of (Types.all, Owed);
         begin
            return IR.Emit_Range_Check
              (Unit.all, Filling, Value, Bounds.Base,
               Bounds.Lower, Bounds.Upper, Site_Of (Of_Tree, Stmt));
         end;
      end Checked_Update;

      function Lower_Unconstrained
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
         function Float_Pattern_Of
           (Literal : Syn.Node_Id; Negated : Boolean := False)
            return Ty.Magnitude;

         function Fixed_Actual_Of
           (Formal : Res.Declaration_Id) return Ty.Magnitude;

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

         function Float_Pattern_Of
           (Literal : Syn.Node_Id; Negated : Boolean := False)
            return Ty.Magnitude
         is
            Text : constant String :=
              Landin.Source.Slice
                (Landin.Stages.Source (Context, Syn.Source_Of (Of_Tree)),
                 Syn.Anchor (Of_Tree, Literal));
            Kind : constant Ty.Float_Name :=
              Ty.Float_Name (Scalar_At (Of_Tree, Literal));
            Bits       : Ty.Magnitude;
            Overflowed : Boolean;
         begin
            Ty.Evaluate_Float (Text, Kind, Bits, Overflowed);
            if Overflowed then
               raise Landin.Compiler_Defect with
                 "a float literal the checker accepted overflowed lowering";
            end if;
            return (if Negated then Ty.Negated_Float (Bits, Kind) else Bits);
         end Float_Pattern_Of;

         --  Fixed routine formals are static arguments rather than runtime
         --  ABI parameters.  The checker interns each concrete routine with
         --  its ordered actual tuple; use the same declaration-order mapping
         --  here and materialize the value as an IR constant.
         function Fixed_Actual_Of
           (Formal : Res.Declaration_Id) return Ty.Magnitude
         is
            View : constant Landin.Checking.Routine_Instance_Id :=
              Landin.Checking.Current_Routine_View (Types.all);
         begin
            if View = Landin.Checking.No_Routine_Instance then
               raise Landin.Compiler_Defect with
                 "a fixed formal reached lowering outside a routine instance";
            end if;

            declare
               Template : constant Res.Declaration_Id :=
                 Landin.Checking.Routine_Template_Of (Types.all, View);
               Template_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Res.Source_Of (Meanings.all, Template));
               Function_Node : constant Syn.Node_Id :=
                 Res.Node_Of (Meanings.all, Template);
            begin
               for Position in 1 .. Syn.Generic_Formal_Count
                 (Template_Tree.all, Function_Node)
               loop
                  if Declaration_At
                    (Syn.Source_Of (Template_Tree.all),
                     Syn.Nth_Generic_Formal
                       (Template_Tree.all, Function_Node, Position)) = Formal
                  then
                     declare
                        Actual : constant Landin.Checking.Actual_Key :=
                          Landin.Checking.Nth_Routine_Actual
                            (Types.all, View, Position);
                     begin
                        if Landin.Checking.Actual_Kind_Of (Actual)
                             /= Landin.Checking.Fixed_Actual_Kind
                        then
                           raise Landin.Compiler_Defect with
                             "a fixed formal maps to a type actual";
                        end if;
                        return Landin.Checking.Fixed_Magnitude_Of (Actual);
                     end;
                  end if;
               end loop;
            end;

            raise Landin.Compiler_Defect with
              "a fixed formal is absent from its routine instance";
         end Fixed_Actual_Of;

      begin
         if Syn.Kind (Of_Tree, Node)
              in Syn.Element_Index | Syn.Member_Selection
           and then
             (Syn.Kind (Of_Tree, Node) /= Syn.Member_Selection
              or else Landin.Checking.Field_Index
                (Types.all, Of_Tree, Node) /= 0
              or else Type_At
                (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Ty.Pointer_Value)
           and then
             (Type_At (Of_Tree, Node)
                in Ty.Function_Value | Ty.Pointer_Value | Ty.Atom_Value
              or else Has_Reference_Storage (Of_Tree, Node)
              or else Has_Computed_Index
                (Of_Tree, Syn.Target_Of (Of_Tree, Node)))
         then
            --  Walk every computed dimension root-outward exactly once.
            --  The scalar child, including a callback signature, witnesses
            --  the indirect access rather than decorating an integer load.
            declare
               Reached : constant Stored_Place :=
                 Lower_Stored_Place (Of_Tree, Node, Scope);
            begin
               if Current = IR.No_Block then
                  return IR.No_Value;
               end if;
               declare
                  Shape : constant IR.Field_Shape :=
                    Neutral_Value_Shape (Of_Tree, Node);
                  Address : constant IR.Storage :=
                    Addressed_Storage (Reached, Shape, Site);
               begin
                  return IR.Emit_Load_Indirect
                    (Unit.all, Filling, Address.Address, Site);
               end;
            end;
         end if;
         if Landin.Checking.Distinct_Conversion_Of
           (Types.all, Of_Tree, Node) /= Landin.Checking.No_Nominal_Type
         then
            declare
               Value : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, 1);
               Temporary : constant IR.Slot_Id :=
                 Shaped_Temporary (Neutral_Value_Shape (Of_Tree, Value), Site);
            begin
               Lower_Stored_Expression (Of_Tree, Value, Scope, Temporary);
               if Current = IR.No_Block then
                  return IR.No_Value;
               end if;
               return IR.Emit_Load_Slot_Field
                 (Unit.all, Filling, Temporary, 1,
                  Scalar_At (Of_Tree, Node), Site,
                  Signature =>
                    (if Type_At (Of_Tree, Node) = Ty.Function_Value
                     then Signature_For
                       (Landin.Checking.Signature_Of
                          (Types.all, Of_Tree, Node))
                     else IR.No_Signature));
            end;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
               | Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               return Lower_Control_Expression (Of_Tree, Node, Scope);

            when Syn.Integer_Literal =>
               return IR.Emit_Number
                        (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                         Magnitude_Of (Node), False, Site);

            when Syn.Float_Literal =>
               return IR.Emit_Float
                        (Unit.all, Filling,
                         Ty.Float_Name (Scalar_At (Of_Tree, Node)),
                         Float_Pattern_Of (Node), Site);

            when Syn.Character_Literal =>
               return IR.Emit_Number
                        (Unit.all, Filling, Ty.U32,
                         Character_Magnitude (Of_Tree, Node), False, Site);

            when Syn.Text_Literal | Syn.Raw_Literal =>
               --  The slice-shaped views are lowered through
               --  Lower_Stored_Expression.  A cstring is its pooled datum's
               --  one-word base address, with no runtime length carrier.
               if Type_At (Of_Tree, Node) /= Ty.Pointer_Value then
                  raise Landin.Compiler_Defect with
                    "a slice text literal reached scalar lowering";
               end if;
               return IR.Emit_Place_Address
                 (Unit.all, Filling,
                  (Kind => IR.Module_Datum,
                   Datum => Text_Datum (Of_Tree, Node)), Site, Field => 1);

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
               elsif Landin.Checking.Type_Of
                       (Types.all, Of_Tree, Node) in Ty.Float_Name
               then
                  return IR.Emit_Float
                           (Unit.all, Filling,
                            Ty.Float_Name (Scalar_At (Of_Tree, Node)),
                            0, Site);
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
                  Of_Code : constant IR.Opcode :=
                    (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                     then IR.Measure_Size else IR.Measure_Align);

                  function Measure_Nominal
                    (Declared : Landin.Checking.Nominal_Type_Id)
                     return IR.Value_Id;
                  function Measure_Shape
                    (Shape : Landin.Checking.Field_Shape)
                     return IR.Value_Id;

                  function Measure_Nominal
                    (Declared : Landin.Checking.Nominal_Type_Id)
                     return IR.Value_Id
                  is
                     Fields : IR.Field_Shape_Array
                       (1 .. Landin.Checking.Layout_Field_Count
                         (Types.all, Declared));
                  begin
                     for Field in Fields'Range loop
                        Fields (Field) := Neutral_Field (Declared, Field);
                     end loop;
                     return IR.Emit_Aggregate_Measurement
                       (Unit.all, Filling, Of_Code, Fields, Result, Site,
                        Policy => Landin.Checking.Layout_Of
                          (Types.all, Declared));
                  end Measure_Nominal;

                  --  [0520]: an array is its element repeated, whatever
                  --  the element is, so the element is measured by its
                  --  shape and the count applied once, the way the
                  --  checker's fold does.  A reference element is one or
                  --  two words, as the direct cases below say.
                  function Measure_Shape
                    (Shape : Landin.Checking.Field_Shape)
                     return IR.Value_Id
                  is
                     function Words (Count : Ty.Magnitude)
                       return IR.Value_Id;

                     function Words (Count : Ty.Magnitude)
                       return IR.Value_Id
                     is
                        Word : constant IR.Value_Id := IR.Emit_Measurement
                          (Unit.all, Filling, Of_Code,
                           Ty.Usize, Result, Site);
                     begin
                        if Count = 1 or else Of_Code = IR.Measure_Align then
                           return Word;
                        end if;
                        return IR.Emit_Binary
                          (Unit.all, Filling, IR.Multiply, Word,
                           IR.Emit_Number
                             (Unit.all, Filling, Result, Count, False, Site),
                           Result, Site);
                     end Words;

                     function Reference_Words
                       (Reference : Landin.Checking.Reference_Id)
                        return IR.Value_Id
                       is (Words
                             (if Landin.Checking.Descriptor_Of
                                   (Types.all, Reference).Kind
                                     in Ty.Slice_Value | Ty.Any_Value
                              then 2 else 1));

                     Element : IR.Value_Id;
                  begin
                     case Shape.Kind is
                        when Landin.Checking.Scalar_Field =>
                           if Shape.Nominal
                                /= Landin.Checking.No_Nominal_Type
                           then
                              return Measure_Nominal (Shape.Nominal);
                           end if;
                           return IR.Emit_Measurement
                             (Unit.all, Filling, Of_Code,
                              Shape.Element, Result, Site);
                        when Landin.Checking.Reference_Field =>
                           return Reference_Words (Shape.Reference);
                        when Landin.Checking.Aggregate_Field =>
                           return Measure_Nominal (Shape.Nominal);
                        when Landin.Checking.Fixed_Array_Field =>
                           if Of_Code = IR.Measure_Align
                             and then Shape.Length = 0
                           then
                              return IR.Emit_Number
                                (Unit.all, Filling, Result, 1, False, Site);
                           end if;
                           if Shape.Reference
                                /= Landin.Checking.No_Reference
                           then
                              Element := Reference_Words (Shape.Reference);
                           elsif Shape.Nominal
                                   /= Landin.Checking.No_Nominal_Type
                           then
                              Element := Measure_Nominal (Shape.Nominal);
                           else
                              Element := IR.Emit_Measurement
                                (Unit.all, Filling, Of_Code,
                                 Shape.Element, Result, Site);
                           end if;
                           if Of_Code = IR.Measure_Align then
                              return Element;
                           end if;
                           return IR.Emit_Binary
                             (Unit.all, Filling, IR.Multiply,
                              IR.Emit_Number
                                (Unit.all, Filling, Result,
                                 Ty.Magnitude (Shape.Length), False, Site),
                              Element, Result, Site);
                        when Landin.Checking.Variant_Field =>
                           raise Landin.Compiler_Defect with
                             "a variant part has no measurement of its own";
                     end case;
                  end Measure_Shape;
               begin
                  if Held = Ty.Aggregate then
                     return Measure_Nominal
                       (Landin.Checking.Nominal_Of
                          (Types.all, Of_Tree, Asked));
                  elsif Held = Ty.Pointer_Value then
                     return IR.Emit_Measurement
                       (Unit.all, Filling, Of_Code, Ty.Usize, Result, Site);
                  elsif Held in Ty.Slice_Value | Ty.Any_Value then
                     if Syn.Kind (Of_Tree, Node) = Syn.Align_Of then
                        return IR.Emit_Measurement
                          (Unit.all, Filling, IR.Measure_Align,
                           Ty.Usize, Result, Site);
                     end if;
                     declare
                        Word : constant IR.Value_Id := IR.Emit_Measurement
                          (Unit.all, Filling, IR.Measure_Size,
                           Ty.Usize, Result, Site);
                        Two : constant IR.Value_Id := IR.Emit_Number
                          (Unit.all, Filling, Result, 2, False, Site);
                     begin
                        return IR.Emit_Binary
                          (Unit.all, Filling, IR.Multiply,
                           Word, Two, Result, Site);
                     end;
                  elsif Held /= Ty.Fixed_Array then
                     return IR.Emit_Measurement
                              (Unit.all, Filling, Of_Code,
                               Ty.Scalar_Name (Held), Result, Site);
                  end if;

                  declare
                     Length : constant Landin.Checking.Element_Count :=
                       Landin.Checking.Array_Length
                         (Types.all, Of_Tree, Asked);
                  begin
                     --  An empty array aligns to a byte and measures
                     --  nothing: the answer is a number, with no
                     --  measurement of an element nobody stores.
                     if Syn.Kind (Of_Tree, Node) = Syn.Align_Of
                       and then Length = 0
                     then
                        return IR.Emit_Number
                                 (Unit.all, Filling, Result, 1, False, Site);
                     end if;
                     declare
                        Element : constant IR.Value_Id := Measure_Shape
                          (Landin.Checking.Array_Element_Shape
                             (Types.all, Of_Tree, Asked));
                     begin
                        if Syn.Kind (Of_Tree, Node) = Syn.Align_Of then
                           return Element;
                        end if;
                        return IR.Emit_Binary
                                 (Unit.all, Filling, IR.Multiply,
                                  IR.Emit_Number
                                    (Unit.all, Filling, Result,
                                     Ty.Magnitude (Length), False, Site),
                                  Element, Result, Site);
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
               begin
                  if Type_At (Of_Tree, Asked) = Ty.Slice_Value then
                     return Lower_Slice (Of_Tree, Asked, Scope).Length;
                  end if;
                  declare
                     Length : constant Ty.Magnitude := Ty.Magnitude
                       (Landin.Checking.Array_Length
                          (Types.all, Of_Tree, Asked));
                  begin
                     return IR.Emit_Number
                       (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                        Length, False, Site);
                  end;
               end;

            when Syn.Pointer_Conversion =>
               declare
                  Value : constant IR.Value_Id := Lower_Expression
                    (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope);
                  Address : IR.Value_Id;
               begin
                  if Current = IR.No_Block then
                     return IR.No_Value;
                  end if;
                  Address := IR.Emit_Conversion
                    (Unit.all, Filling, Value, Ty.Usize, Site);
                  --  The reserved zero is tested after target-width
                  --  conversion.  Range_Check is deliberately never
                  --  removable by an unchecked region.  Foreign optional
                  --  results do not pass through pointer construction.
                  return IR.Emit_Range_Check
                    (Unit.all, Filling, Address, Ty.Usize, 1,
                     Ty.Folded
                       (Landin.Targets.Maximum_Object_Size (Facts)), Site);
               end;

            when Syn.Address_Of =>
               declare
                  Place : constant Stored_Place :=
                    Lower_Stored_Place
                      (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Scope);
               begin
                  return IR.Emit_Place_Address
                    (Unit.all, Filling, Place.Place, Site,
                     Field => Place.Base, Nested => Stored_Steps (Place));
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
                  elsif Syn.Kind (Of_Tree, Under) = Syn.Float_Literal then
                     return IR.Emit_Float
                              (Unit.all, Filling,
                               Ty.Float_Name (Scalar_At (Of_Tree, Node)),
                               Float_Pattern_Of
                                 (Under, Negated => True),
                               Site);
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
               if Has_Reference_Storage (Of_Tree, Node)
                 and then Type_At
                   (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Ty.Fixed_Array
               then
                  declare
                     Place : constant Stored_Place :=
                       Lower_Stored_Place (Of_Tree, Node, Scope);
                  begin
                     if Current = IR.No_Block then
                        return IR.No_Value;
                     end if;
                     declare
                        Address : constant IR.Value_Id :=
                          (if Place.Base = 0 and then Place.Steps.Is_Empty
                           then IR.Emit_Load
                             (Unit.all, Filling, Place.Place.Address, Site)
                           else IR.Emit_Storage_Address
                             (Unit.all, Filling, Place.Place, Site,
                              Field => Place.Base,
                              Nested => Stored_Steps (Place)));
                     begin
                        return IR.Emit_Load_Indirect
                          (Unit.all, Filling, Address,
                           Scalar_At (Of_Tree, Node), Site);
                     end;
                  end;
               end if;

               if Type_At
                    (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Ty.Slice_Value
               then
                  declare
                     Parts : constant Slice_Values := Lower_Slice
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
                     Saved_Base : constant IR.Slot_Id := IR.Add_Slot
                       (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
                     Saved_Length : constant IR.Slot_Id := IR.Add_Slot
                       (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Saved_Base, Parts.Base, Site);
                     IR.Emit_Store
                       (Unit.all, Filling, Saved_Length, Parts.Length, Site);
                     declare
                        Index : constant IR.Value_Id := Lower_Expression
                          (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
                        Base : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Saved_Base, Site);
                        Length : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Saved_Length, Site);
                        Address : constant IR.Value_Id :=
                          IR.Emit_Slice_Address
                            (Unit.all, Filling, Base, Length, Index, Index,
                             Slice_Shape
                               (Of_Tree, Syn.Target_Of (Of_Tree, Node)),
                             True, Site);
                     begin
                        return IR.Emit_Load_Indirect
                          (Unit.all, Filling, Address,
                           Scalar_At (Of_Tree, Node), Site);
                     end;
                  end;
               end if;

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
                        Element_Path : constant IR.Path_Step_Array :=
                          Alias_Element_Steps
                            (Of_Tree, Alias,
                             Chain_All_Steps (Of_Tree, From));
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
                                 Nested => Element_Path,
                                 Variant_Case =>
                                   (if Element_Path'Length = 0
                                    then Alias.Which else 0),
                                 Variant_Payload_Field =>
                                   (if Element_Path'Length = 0
                                    then Alias.Payload_Field else 0));
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Alias.Source.Slot,
                                 Index, Scalar_At (Of_Tree, Node), Site,
                                 Field => Alias.Field,
                                 Nested => Element_Path,
                                 Variant_Case =>
                                   (if Element_Path'Length = 0
                                    then Alias.Which else 0),
                                 Variant_Payload_Field =>
                                   (if Element_Path'Length = 0
                                    then Alias.Payload_Field else 0));
                           when IR.Runtime_Address =>
                              declare
                                 Address : constant IR.Value_Id :=
                                   (if Alias.Which = 0 then
                                       IR.Emit_Storage_Address
                                         (Unit.all, Filling, Alias.Source,
                                          Site, Index => Index)
                                    else
                                       IR.Emit_Storage_Address
                                         (Unit.all, Filling, Alias.Source,
                                          Site, Field => Alias.Field,
                                          Nested => Payload_Steps
                                            (Alias_Steps (Of_Tree, Alias),
                                             Positive (Alias.Which),
                                             Positive (Alias.Payload_Field)),
                                          Index => Index));
                              begin
                                 return IR.Emit_Load_Indirect
                                   (Unit.all, Filling, Address,
                                    Scalar_At (Of_Tree, Node), Site);
                              end;
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
               if Is_Float_Special (Of_Tree, Node) then
                  return IR.Emit_Float
                    (Unit.all, Filling,
                     Ty.Float_Name (Scalar_At (Of_Tree, Node)),
                     Float_Special_At (Of_Tree, Node), Site);
               end if;

               --  Resolution binds an imported `module.member` directly to
               --  the public declaration.  Its namespace target is not a
               --  runtime value, so lower the selected declaration exactly
               --  as an unqualified module name before considering ordinary
               --  field and evidence selections.
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
               then
                  declare
                     Means : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, Node);
                  begin
                     if Res.Sort_Of (Meanings.all, Means) = Res.Module_Atom
                     then
                        --  D189/[0480]: in a pointer-union position the
                        --  atom is the reserved zero, not its own dense
                        --  atom code.  Checking has already noted this
                        --  node as the union's pointer type, so the kind
                        --  is what says which of the two is meant.
                        if Type_At (Of_Tree, Node) = Ty.Pointer_Value then
                           return IR.Emit_Number
                             (Unit.all, Filling, Ty.Usize, 0, False, Site);
                        end if;
                        return IR.Emit_Atom
                          (Unit.all, Filling, Means,
                           Atom_Set_For
                             (Landin.Checking.Atom_Set_Of
                                (Types.all, Means)),
                           Site);
                     elsif Res.Sort_Of (Meanings.all, Means)
                       = Res.Module_Function
                     then
                        return IR.Emit_Function_Address
                          (Unit.all, Filling, IR.Item_For (Unit.all, Means),
                           Site);
                     elsif Res.Sort_Of (Meanings.all, Means)
                       = Res.Module_Binding
                     then
                        return IR.Emit_Load_Datum
                          (Unit.all, Filling, IR.Item_For (Unit.all, Means),
                           Site);
                     end if;

                     raise Landin.Compiler_Defect with
                       "a non-value imported declaration reached lowering";
                  end;
               end if;

               if Landin.Checking.Evidence_Of
                 (Types.all, Of_Tree, Node)
                    /= Landin.Checking.No_Conformance
               then
                  declare
                     Source : constant Landin.Checking.Conformance_Id :=
                       Landin.Checking.Evidence_Of
                         (Types.all, Of_Tree, Node);
                     Position : constant Positive :=
                       Landin.Checking.Conformance_Identities.Position
                         (Types.all, Source);
                     Slot : constant IR.Slot_Id := Evidence_Slots (Position);
                     Dynamic : constant Boolean := Type_At
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                         = Ty.Any_Value;
                     Table : IR.Value_Id;
                  begin
                     if Dynamic then
                        raise Landin.Compiler_Defect with
                          "a bound any entry escaped call lowering";
                     elsif Slot = IR.No_Slot then
                        raise Landin.Compiler_Defect with
                          "an evidence selection has no hidden parameter";
                     else
                        Table := IR.Emit_Load
                          (Unit.all, Filling, Slot, Site);
                     end if;
                     return IR.Emit_Evidence_Function
                       (Unit.all, Filling, Table,
                        Evidence_For (Source),
                        Positive
                          (Landin.Checking.Evidence_Entry_Of
                             (Types.all, Of_Tree, Node)),
                        Site);
                  end;
               end if;

               declare
                  Cursor : Syn.Node_Id := Node;
                  Through_Pointer : Boolean := False;
               begin
                  while Syn.Kind (Of_Tree, Cursor)
                    in Syn.Member_Selection | Syn.Element_Index
                  loop
                     if (Syn.Kind (Of_Tree, Cursor) = Syn.Member_Selection
                          and then Landin.Checking.Field_Index
                            (Types.all, Of_Tree, Cursor) = 0
                          and then Type_At
                            (Of_Tree, Syn.Target_Of (Of_Tree, Cursor))
                              = Ty.Pointer_Value)
                       or else
                         (Syn.Kind (Of_Tree, Cursor) = Syn.Element_Index
                          and then Type_At
                            (Of_Tree, Syn.Target_Of (Of_Tree, Cursor))
                              = Ty.Slice_Value)
                     then
                        Through_Pointer := True;
                        exit;
                     end if;
                     Cursor := Syn.Target_Of (Of_Tree, Cursor);
                  end loop;
                  if (Through_Pointer
                      or else Has_Computed_Index (Of_Tree, Node))
                    and then not
                      (Type_At
                         (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                           = Ty.Pointer_Value
                       and then Landin.Checking.Field_Index
                         (Types.all, Of_Tree, Node) = 0)
                    and then Type_At (Of_Tree, Node)
                      not in Ty.Aggregate | Ty.Fixed_Array
                  then
                     declare
                        Place : constant Stored_Place :=
                          Lower_Stored_Place (Of_Tree, Node, Scope);
                     begin
                        if Current = IR.No_Block then
                           return IR.No_Value;
                        end if;
                        return IR.Emit_Load_Slot_Field
                          (Unit.all, Filling, Place.Place.Address,
                           IR.Part_Position (Place.Base),
                           Scalar_At (Of_Tree, Node), Site,
                           Nested => Stored_Steps (Place),
                           Signature =>
                             (if Type_At (Of_Tree, Node) = Ty.Function_Value
                              then Signature_For
                                (Landin.Checking.Signature_Of
                                   (Types.all, Of_Tree, Node))
                              else IR.No_Signature));
                     end;
                  end if;
               end;

               if Type_At
                    (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                    = Ty.Pointer_Value
                 and then Landin.Checking.Field_Index
                   (Types.all, Of_Tree, Node) = 0
               then
                  declare
                     Address : constant IR.Value_Id := Lower_Expression
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node), Scope);
                  begin
                     if Current = IR.No_Block then
                        return IR.No_Value;
                     end if;
                     return IR.Emit_Load_Indirect
                       (Unit.all, Filling, Address,
                        Scalar_At (Of_Tree, Node), Site);
                  end;
               end if;

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
                        return IR.Emit_Load_Slot_Field
                          (Unit.all, Filling, Place.Address,
                           Leaf_Base (Base, Child_Steps),
                           Scalar_At (Of_Tree, Node), Site,
                           Nested => Leaf_Steps (Base, Child_Steps),
                           Signature => Value_Signature);
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
                  if Res.Sort_Of (Meanings.all, Means)
                       = Res.Fixed_Parameter
                  then
                     return IR.Emit_Number
                       (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                        Fixed_Actual_Of (Means), False, Site);
                  end if;

                  if Aliases (Declared (Means)).Active then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                        Held : constant Ty.Type_Kind :=
                          Landin.Checking.Type_Of (Types.all, Means);
                        Carrier : constant Ty.Scalar_Name :=
                          (if Held in Ty.Function_Value | Ty.Pointer_Value
                           then Ty.Usize
                           elsif Held = Ty.Atom_Value then Ty.U32
                           else Ty.Scalar_Name (Held));
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
                              Signature => Signature,
                              Atoms =>
                                (if Held = Ty.Atom_Value
                                 then Atom_Set_For
                                   (Landin.Checking.Atom_Set_Of
                                      (Types.all, Means))
                                 else IR.No_Atom_Set));
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
                              --  D160: a traversal element aliases one
                              --  element of runtime storage, so the value
                              --  is read through the address it keeps.
                              if Alias.Field /= 0 then
                                 raise Landin.Compiler_Defect with
                                   "a runtime aggregate alias reached"
                                   & " direct scalar lowering";
                              end if;
                              return IR.Emit_Load_Indirect
                                (Unit.all, Filling,
                                 Alias.Source.Address, Site);
                        end case;
                     end;
                  end if;

                  if Res.Sort_Of (Meanings.all, Means) = Res.Module_Atom then
                     --  D189/[0480]: see the Member_Selection arm above --
                     --  a union's empty case lowers to the reserved zero.
                     if Type_At (Of_Tree, Node) = Ty.Pointer_Value then
                        return IR.Emit_Number
                          (Unit.all, Filling, Ty.Usize, 0, False, Site);
                     end if;
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

                  if Res.Sort_Of (Meanings.all, Means) = Res.Parameter then
                     declare
                        Their_Tree : constant not null access constant
                          Syn.Tree :=
                            Tree_For (Res.Source_Of (Meanings.all, Means));
                        Their_Node : constant Syn.Node_Id :=
                          Res.Node_Of (Meanings.all, Means);
                     begin
                        if Syn.Convention_Of (Their_Tree.all, Their_Node)
                             = Syn.Inout_Convention
                        then
                           return IR.Emit_Load_Indirect
                             (Unit.all, Filling,
                              Slot_For (Of_Tree, Node, Means), Site);
                        end if;
                     end;
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
               if Conversion_Scalar (Of_Tree, Node) in Ty.Scalar_Name then
                  declare
                     Value : constant IR.Value_Id := Lower_Expression
                       (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, 1), Scope);
                  begin
                     return IR.Emit_Conversion
                       (Unit.all, Filling, Value,
                        Ty.Scalar_Name (Conversion_Scalar (Of_Tree, Node)),
                        Site);
                  end;
               end if;
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
                          Pointee => IR.Pointee_Of (Unit.all, Filling, Left),
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
      end Lower_Unconstrained;

      --  D185 represents a condition declaration as the ordinary Binding it
      --  introduces.  Evaluate the initializer in the surrounding scope,
      --  store it for references in the guarded body, and test that same
      --  value.  A while calls this at its head, so the declaration is
      --  initialized afresh on every condition test.
      function Lower_Condition
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Binding then
            return Lower_Expression (Of_Tree, Node, Scope);
         end if;

         declare
            Id : constant Res.Declaration_Id :=
              Declaration_At (Syn.Source_Of (Of_Tree), Node);
            Where : constant IR.Slot_Id := Slot_For (Of_Tree, Node, Id);
            Value : constant IR.Value_Id :=
              Lower_Expression
                (Of_Tree, Syn.Value_Of (Of_Tree, Node), Scope);
         begin
            if Current = IR.No_Block then
               return IR.No_Value;
            end if;
            IR.Emit_Store
              (Unit.all, Filling, Where, Value, Site_Of (Of_Tree, Node));
            return Value;
         end;
      end Lower_Condition;

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
                 Lower_Condition
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
         Referenced : constant Boolean :=
           Has_Reference_Storage (Of_Tree, Holder);
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
                  IR.Note_Source_Alias
                    (Unit.all, Filling,
                     (Binding => Id, Site => Site_Of (Of_Tree, Binding),
                      Place => Location.Place, Field => Location.Base,
                      Initialized_On_Entry => True),
                     Payload_Steps
                       (Stored_Steps (Location), Which, Payload));
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

         if Referenced then
            --  An inout, pointer or slice subject names existing storage.
            --  Capture its shaped address once, not a copy of its bytes:
            --  payload writes and returned views must reach the caller.
            Location := Lower_Stored_Place (Of_Tree, Holder, Scope);
            if Current = IR.No_Block then
               return;
            end if;
            Location.Place := Addressed_Storage
              (Location, Neutral_Body (Wrote), Site);
            Location.Base := Field;
            Location.Steps.Clear;
            Alias_Subject := Syn.No_Node;
         elsif Computed then
            --  D134's computed value subject keeps its independent copy.
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

      procedure Lower_Pointer_Union_Match
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
         --  The union and its present binding share the pointer's reached
         --  type as well as its carrier. Preserve that witness while the
         --  subject crosses the dispatch blocks; a bare usize would erase
         --  it before Bind stores the value into the narrowed pointer slot.
         Saved : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site,
              Pointee => Pointee_For
                (Landin.Checking.Reference_Of (Types.all, Of_Tree, Subject)));
         Merge : IR.Block_Id := IR.No_Block;

         procedure Bind (Arm : Syn.Node_Id);
         procedure Close_To_Merge;

         --  The present case is the union's own carrier, so the binding is
         --  the same value the subject already held.
         procedure Bind (Arm : Syn.Node_Id) is
         begin
            if Syn.Kind (Of_Tree, Syn.Match_Pattern (Of_Tree, Arm))
                 /= Syn.Pointer_Case
              or else Syn.Match_Binding_Count (Of_Tree, Arm) = 0
            then
               return;
            end if;
            declare
               Binding : constant Syn.Node_Id :=
                 Syn.Nth_Match_Binding (Of_Tree, Arm, 1);
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Syn.Source_Of (Of_Tree), Binding);
            begin
               if Id = Res.No_Declaration then
                  return;
               end if;
               IR.Emit_Store
                 (Unit.all, Filling, Slot_For (Of_Tree, Binding, Id),
                  IR.Emit_Load (Unit.all, Filling, Saved, Site), Site);
            end;
         end Bind;

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
               Present : constant Boolean :=
                 Syn.Kind (Of_Tree, Pattern) = Syn.Pointer_Case;
               Wildcard : constant Boolean :=
                 not Present
                 and then Syn.Name (Of_Tree, Pattern)
                            = Landin.Source.Names.No_Name;
               Last : constant Boolean :=
                 Position = Syn.Match_Arm_Count (Of_Tree, Node);
            begin
               if Wildcard or else Last then
                  Close_With_Jump (Taken, Site);
                  Open (Taken);
                  Bind (Arm);
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
                     Got : constant IR.Value_Id :=
                       IR.Emit_Load (Unit.all, Filling, Saved, Site);
                     Zero : constant IR.Value_Id :=
                       IR.Emit_Number
                         (Unit.all, Filling, Ty.Usize, 0, False, Site);
                     Test : constant IR.Value_Id :=
                       IR.Emit_Binary
                         (Unit.all, Filling,
                          (if Present then IR.Not_Equal_To
                           else IR.Equal_To),
                          Got, Zero, Ty.Bool, Site);
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
               end if;
            end;
         end loop;

         if Merge /= IR.No_Block then
            Open (Merge);
         end if;
      end Lower_Pointer_Union_Match;

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
         elsif Type_At (Of_Tree, Syn.Match_Subject (Of_Tree, Node))
                 = Ty.Pointer_Value
         then
            Lower_Pointer_Union_Match
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
         --  D187: [1120]'s region is this same block, carrying a flag.
         --  The mode is entered around the body only, so an edge emitted
         --  outside it -- a later statement, or a separately filled item
         --  such as [1010]'s anonymous function body -- stays checked.
         Region : constant Boolean := Syn.Is_Unchecked (Of_Tree, Node);
      begin
         Close_With_Jump (Start, Site);
         Open (Start);
         if Region then
            IR.Begin_Unchecked (Unit.all, Filling);
         end if;
         Lower_Statements
           (Of_Tree, Runs, Inside, Result, Destination,
            Destination_Field, Destination_Path);
         if Region then
            IR.End_Unchecked (Unit.all, Filling);
         end if;
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

      function Block_Has_Break
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Target  : Landin.Source.Names.Name_Id;
         Nested  : Boolean := False) return Boolean;

      function Block_Has_Break
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Target  : Landin.Source.Names.Name_Id;
         Nested  : Boolean := False) return Boolean
      is
         function Walk (Node : Syn.Node_Id; Inside_Loop : Boolean)
           return Boolean;

         function Walk (Node : Syn.Node_Id; Inside_Loop : Boolean)
           return Boolean
         is
            Deeper : Boolean := Inside_Loop;
         begin
            if Node = Syn.No_Node then
               return False;
            end if;
            case Syn.Kind (Of_Tree, Node) is
               when Syn.Anonymous_Function | Syn.Function_Declaration =>
                  return False;
               when Syn.Break_Statement =>
                  return
                    (if Syn.Name (Of_Tree, Node)
                          = Landin.Source.Names.No_Name
                     then not Inside_Loop
                     else Syn.Name (Of_Tree, Node) = Target);
               when Syn.Loop_Statement | Syn.While_Statement
                  | Syn.For_Statement =>
                  if Target = Landin.Source.Names.No_Name
                    or else Syn.Name (Of_Tree, Node) = Target
                  then
                     return False;
                  end if;
                  Deeper := True;
               when others =>
                  null;
            end case;
            --  A transfer can be inside a value-position begin, condition
            --  or argument. Walk expression children as well as statements.
            for Index in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               if Walk (Syn.Slot (Of_Tree, Node, Index), Deeper) then
                  return True;
               end if;
            end loop;
            if Syn.Kind (Of_Tree, Node) in Syn.Call | Syn.Labeled_Application
              and then Syn.Recovery_Of (Of_Tree, Node) /= Syn.No_Node
            then
               --  Recovery is beside the ordinary slots, and its transfers
               --  need the same loop destination as successful expressions.
               return Walk (Syn.Recovery_Of (Of_Tree, Node), Deeper);
            end if;
            return False;
         end Walk;
      begin
         return Walk (Block, Nested);
      end Block_Has_Break;

      procedure Lower_Loop
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id;
         Destination : IR.Slot_Id := IR.No_Slot;
         Destination_Field : Natural := 0;
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps)
      is
         Enclosing_Depth : constant Natural :=
           IR.Loop_Depth (Unit.all, Filling);
         Site : constant Landin.Provenance.Origin := Site_Of (Of_Tree, Node);
         Runs : constant Syn.Node_Id := Syn.Loop_Body (Of_Tree, Node);
         Inside : constant Res.Scope_Id :=
           Res.Scope_At (Meanings.all, Of_Tree, Runs);
         Is_While : constant Boolean :=
           Syn.Kind (Of_Tree, Node) = Syn.While_Statement;
         Is_For : constant Boolean :=
           Syn.Kind (Of_Tree, Node) = Syn.For_Statement;
         --  D160: a traversal with no upper bound walks a slice or a fixed
         --  array.  Its element binding is an alias into that storage,
         --  refreshed from a hidden `usize` counter before every body run.
         Is_Collection : constant Boolean :=
           Is_For
           and then Syn.Traversal_Upper (Of_Tree, Node) = Syn.No_Node;
         Collection_Source : constant Syn.Node_Id :=
           (if Is_Collection
            then Syn.Traversal_Lower (Of_Tree, Node) else Syn.No_Node);
         Collection_View : constant Ty.Reference_View :=
           (if Is_Collection
              and then Type_At (Of_Tree, Collection_Source)
                in Ty.Pointer_Value | Ty.Slice_Value
            then Landin.Checking.Descriptor_Of
              (Types.all,
               Landin.Checking.Reference_Of
                 (Types.all, Of_Tree, Collection_Source)).View
            else Ty.Ordinary_View);
         Is_Text : constant Boolean :=
           Collection_View in Ty.Text_View;
         Traversal_Evidence : constant Landin.Checking.Conformance_Id :=
           (if Is_Collection
            then Landin.Checking.Traversal_Evidence_Of
              (Types.all, Of_Tree, Node)
            else Landin.Checking.No_Conformance);
         Is_Evidence : constant Boolean :=
           Traversal_Evidence /= Landin.Checking.No_Conformance;
         Is_Storage_Collection : constant Boolean :=
           Is_Collection and then not Is_Evidence and then not Is_Text;
         Is_Range : constant Boolean := Is_For and then not Is_Collection;
         Head : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
         Body_Block : constant IR.Block_Id := Fresh (Of_Tree, Runs, Inside);
         Has_Complete : constant Boolean :=
           (Is_While or else Is_For)
           and then Syn.Complete_Body (Of_Tree, Node) /= Syn.No_Node;
         Has_Exit : constant Boolean :=
           Is_While or else Is_For
           or else Block_Has_Break
             (Of_Tree, Runs, Syn.Name (Of_Tree, Node));
         Exit_Block : constant IR.Block_Id :=
           (if Has_Exit then Fresh (Of_Tree, Node, Scope) else IR.No_Block);
         Complete_Block : constant IR.Block_Id :=
           (if Has_Complete
            then Fresh
              (Of_Tree, Syn.Complete_Body (Of_Tree, Node), Scope)
            else IR.No_Block);
         Natural_Exit : constant IR.Block_Id :=
           (if Has_Complete then Complete_Block else Exit_Block);
         Step_Block : constant IR.Block_Id :=
           (if Is_For then Fresh (Of_Tree, Node, Inside) else IR.No_Block);
         Entry_Block : constant IR.Block_Id :=
           (if Is_For then Fresh (Of_Tree, Node, Scope) else IR.No_Block);
         Increment_Block : constant IR.Block_Id :=
           (if Is_Range and then Syn.Traversal_Is_Inclusive (Of_Tree, Node)
            then Fresh (Of_Tree, Node, Inside) else Step_Block);
         Element_Node : constant Syn.Node_Id :=
           (if Is_For
            then Syn.Traversal_Element (Of_Tree, Node) else Syn.No_Node);
         Element_Id : constant Res.Declaration_Id :=
           (if Is_For
            then Declaration_At (Syn.Source_Of (Of_Tree), Element_Node)
            else Res.No_Declaration);
         Element_Slot : constant IR.Slot_Id :=
           (if Is_Range or else Is_Evidence or else Is_Text
            then Slot_For (Of_Tree, Element_Node, Element_Id)
            else IR.No_Slot);
         Index_Node : constant Syn.Node_Id :=
           (if Is_For
            then Syn.Traversal_Index (Of_Tree, Node) else Syn.No_Node);
         Index_Id : constant Res.Declaration_Id :=
           (if Index_Node /= Syn.No_Node
            then Declaration_At (Syn.Source_Of (Of_Tree), Index_Node)
            else Res.No_Declaration);
         Index_Slot : constant IR.Slot_Id :=
           (if Index_Node /= Syn.No_Node
            then Slot_For (Of_Tree, Index_Node, Index_Id)
            else IR.No_Slot);
         Range_Type : constant Ty.Integer_Name :=
           (if Is_Range
            then Ty.Integer_Name
              (Scalar_At (Of_Tree, Syn.Traversal_Lower (Of_Tree, Node)))
            else Ty.I32);
         Upper_Slot : IR.Slot_Id := IR.No_Slot;
         --  The collection form's hidden state: where the storage starts,
         --  how many elements it holds, which one the body is at, and the
         --  address the element alias reads and writes through.  The
         --  source's index binding, when written, is the counter itself.
         Base_Slot : IR.Slot_Id := IR.No_Slot;
         Length_Slot : IR.Slot_Id := IR.No_Slot;
         Counter_Slot : IR.Slot_Id := IR.No_Slot;
         Address_Slot : IR.Slot_Id := IR.No_Slot;
         Element_Shape : IR.Field_Shape;
         Source_Slot : IR.Slot_Id := IR.No_Slot;
         Cursor_Slot : IR.Slot_Id := IR.No_Slot;
         Text_Width_Slot : IR.Slot_Id := IR.No_Slot;
         Cursor_Part : Landin.Checking.Signature_Part;

         function Provider_Signature
           (Position : Positive) return Landin.Checking.Signature_Id;

         function Provider_Signature
           (Position : Positive) return Landin.Checking.Signature_Id
         is
            Instance : constant Landin.Checking.Routine_Instance_Id :=
              Landin.Checking.Conformance_Provider_Instance
                (Types.all, Traversal_Evidence, Position);
            Provider : constant Res.Declaration_Id :=
              Landin.Checking.Conformance_Provider_Declaration
                (Types.all, Traversal_Evidence, Position);
         begin
            if Instance /= Landin.Checking.No_Routine_Instance then
               return Landin.Checking.Routine_Signature_Of
                 (Types.all, Instance);
            end if;
            return Landin.Checking.Signature_Of (Types.all, Provider);
         end Provider_Signature;

         function Is_Stored
           (Part : Landin.Checking.Signature_Part) return Boolean
           is (Part.Kind in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
                 | Ty.Any_Value);

         function Add_Part_Slot
           (Part : Landin.Checking.Signature_Part) return IR.Slot_Id;

         function Add_Part_Slot
           (Part : Landin.Checking.Signature_Part) return IR.Slot_Id
         is
            Made : IR.Slot_Id;
         begin
            if Part.Kind in Ty.Slice_Value | Ty.Any_Value then
               return IR.Add_Array_Slot
                 (Unit.all, Filling, Ty.Usize, 2, Res.No_Declaration, Site);
            elsif Part.Kind = Ty.Fixed_Array then
               return IR.Add_Array_Slot
                 (Unit.all, Filling, Neutral_Element (Part),
                  IR.Element_Total (Part.Length), Res.No_Declaration, Site);
            elsif Part.Kind = Ty.Aggregate then
               Made := IR.Add_Aggregate_Slot
                 (Unit.all, Filling, Res.No_Declaration, Site,
                  Nominal_For (Part.Nominal));
               for Field in 1 .. Landin.Checking.Layout_Field_Count
                 (Types.all, Part.Nominal)
               loop
                  Add_Stored_Field (Part.Nominal, Field, Slot => Made);
               end loop;
               return Made;
            end if;
            return IR.Add_Slot
              (Unit.all, Filling,
               (if Part.Kind in Ty.Function_Value | Ty.Pointer_Value
                then Ty.Usize
                elsif Part.Kind = Ty.Atom_Value then Ty.U32
                else Ty.Scalar_Name (Part.Kind)),
               Res.No_Declaration, Site,
               Pointee =>
                 (if Part.Kind = Ty.Pointer_Value
                  then Pointee_For (Part.Reference) else IR.No_Pointee),
               Signature =>
                 (if Part.Kind = Ty.Function_Value
                  then Signature_For (Part.Signature)
                  else IR.No_Signature),
               Atoms =>
                 (if Part.Kind = Ty.Atom_Value
                  then Atom_Set_For (Part.Atoms)
                  else IR.No_Atom_Set));
         end Add_Part_Slot;

         function Part_Argument
           (Slot : IR.Slot_Id;
            Part : Landin.Checking.Signature_Part) return IR.Value_Id;

         function Part_Argument
           (Slot : IR.Slot_Id;
            Part : Landin.Checking.Signature_Part) return IR.Value_Id is
         begin
            if Is_Stored (Part) then
               return IR.Emit_Storage_Address
                 (Unit.all, Filling,
                  (Kind => IR.Frame_Slot, Slot => Slot), Site);
            end if;
            return IR.Emit_Load (Unit.all, Filling, Slot, Site);
         end Part_Argument;

         procedure Copy_Part
           (Source, Destination : IR.Slot_Id;
            Part : Landin.Checking.Signature_Part);

         procedure Copy_Part
           (Source, Destination : IR.Slot_Id;
            Part : Landin.Checking.Signature_Part) is
         begin
            if Part.Kind = Ty.Aggregate then
               declare
                  Shape : constant IR.Field_Shape :=
                    Neutral_Body (Part.Nominal);
                  Source_Address : constant IR.Slot_Id :=
                    IR.Add_Address_Slot (Unit.all, Filling, Shape, Site);
                  Destination_Address : constant IR.Slot_Id :=
                    IR.Add_Address_Slot (Unit.all, Filling, Shape, Site);
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Source_Address,
                     IR.Emit_Storage_Address
                       (Unit.all, Filling,
                        (Kind => IR.Frame_Slot, Slot => Source), Site),
                     Site);
                  IR.Emit_Store
                    (Unit.all, Filling, Destination_Address,
                     IR.Emit_Storage_Address
                       (Unit.all, Filling,
                        (Kind => IR.Frame_Slot, Slot => Destination), Site),
                     Site);
                  IR.Emit_Array_Copy
                    (Unit.all, Filling,
                     (Kind => IR.Runtime_Address,
                      Address => Source_Address),
                     (Kind => IR.Runtime_Address,
                      Address => Destination_Address), Site);
               end;
            elsif Is_Stored (Part) then
               IR.Emit_Array_Copy
                 (Unit.all, Filling,
                  (Kind => IR.Frame_Slot, Slot => Source),
                  (Kind => IR.Frame_Slot, Slot => Destination), Site);
            else
               IR.Emit_Store
                 (Unit.all, Filling, Destination,
                  IR.Emit_Load (Unit.all, Filling, Source, Site), Site);
            end if;
         end Copy_Part;

         function Call_Entry
           (Position    : Positive;
            Result_Part : Landin.Checking.Signature_Part;
            Destination : IR.Slot_Id;
            With_Cursor : Boolean) return IR.Value_Id;

         function Call_Entry
           (Position    : Positive;
            Result_Part : Landin.Checking.Signature_Part;
            Destination : IR.Slot_Id;
            With_Cursor : Boolean) return IR.Value_Id
         is
            Source_Signature : constant Landin.Checking.Signature_Id :=
              Provider_Signature (Position);
            Signature : constant IR.Signature_Id :=
              Signature_For (Source_Signature);
            Table : constant IR.Value_Id := IR.Emit_Evidence_Address
              (Unit.all, Filling, Evidence_For (Traversal_Evidence), Site);
            Callee : constant IR.Value_Id := IR.Emit_Evidence_Function
              (Unit.all, Filling, Table, Evidence_For (Traversal_Evidence),
               Position, Site);
            Hidden : constant IR.Value_Id :=
              (if Is_Stored (Result_Part)
               then IR.Emit_Storage_Address
                 (Unit.all, Filling,
                  (Kind => IR.Frame_Slot, Slot => Destination), Site)
               else IR.No_Value);
            Source_Argument : constant IR.Value_Id :=
              IR.Emit_Storage_Address
                (Unit.all, Filling,
                 (Kind => IR.Frame_Slot, Slot => Source_Slot), Site);
            Cursor_Argument : constant IR.Value_Id :=
              (if With_Cursor
               then Part_Argument (Cursor_Slot, Cursor_Part)
               else IR.No_Value);
            Made : constant IR.Value_Id := IR.Emit_Indirect_Call
              (Unit.all, Filling, Signature,
               (if Is_Stored (Result_Part) then Ty.No_Value
                elsif Result_Part.Kind
                  in Ty.Function_Value | Ty.Pointer_Value
                then Ty.Usize
                elsif Result_Part.Kind = Ty.Atom_Value then Ty.U32
                else Ty.Scalar_Name (Result_Part.Kind)),
               Site);
         begin
            IR.Add_Argument (Unit.all, Filling, Made, Callee);
            if Hidden /= IR.No_Value then
               IR.Add_Argument (Unit.all, Filling, Made, Hidden);
            end if;
            IR.Add_Argument (Unit.all, Filling, Made, Source_Argument);
            if Cursor_Argument /= IR.No_Value then
               IR.Add_Argument (Unit.all, Filling, Made, Cursor_Argument);
            end if;
            return Made;
         end Call_Entry;

         function Text_Unit_At
           (Relative : Ty.Magnitude) return IR.Value_Id;
         procedure Decode_Text_Item;

         --  D184's intrinsic iterable providers retain a code-unit cursor.
         --  Length-bearing text uses the verified slice-address operation;
         --  cstring uses its read-only base and stops before asking for an
         --  item at the first NUL.  No backing slice or pointer enters the
         --  source program's type system through either path.
         function Text_Unit_At
           (Relative : Ty.Magnitude) return IR.Value_Id
         is
            Position : IR.Value_Id :=
              IR.Emit_Load (Unit.all, Filling, Cursor_Slot, Site);
            Address : IR.Value_Id;
            Element : constant Ty.Scalar_Name :=
              (if Collection_View = Ty.Utf16_View then Ty.U16 else Ty.U8);
         begin
            if Relative /= 0 then
               Position := IR.Emit_Binary
                 (Unit.all, Filling, IR.Add, Position,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, Relative, False, Site),
                  Ty.Usize, Site);
            end if;
            if Collection_View = Ty.C_String_View then
               Address := IR.Emit_Binary
                 (Unit.all, Filling, IR.Add,
                  IR.Emit_Load (Unit.all, Filling, Base_Slot, Site),
                  Position, Ty.Usize, Site);
            else
               Address := IR.Emit_Slice_Address
                 (Unit.all, Filling,
                  IR.Emit_Load (Unit.all, Filling, Base_Slot, Site),
                  IR.Emit_Load (Unit.all, Filling, Length_Slot, Site),
                  Position, Position, Element_Shape, True, Site,
                  Required => True);
            end if;
            return IR.Emit_Load_Indirect
              (Unit.all, Filling, Address, Element, Site);
         end Text_Unit_At;

         procedure Decode_Text_Item is
            function As_U32 (Value : IR.Value_Id) return IR.Value_Id;
            function Literal (Value : Ty.Magnitude) return IR.Value_Id;
            function Minus
              (Value : IR.Value_Id; Bias : Ty.Magnitude)
               return IR.Value_Id;
            function Times
              (Value : IR.Value_Id; Factor : Ty.Magnitude)
               return IR.Value_Id;
            function Plus
              (Left, Right : IR.Value_Id) return IR.Value_Id;
            procedure Keep (Value : IR.Value_Id; Width : Ty.Magnitude);
            procedure Validate_C_String_Scalar (Lead : IR.Value_Id);

            function As_U32 (Value : IR.Value_Id) return IR.Value_Id is
              (IR.Emit_Conversion
                 (Unit.all, Filling, Value, Ty.U32, Site));

            function Literal (Value : Ty.Magnitude) return IR.Value_Id is
              (IR.Emit_Number
                 (Unit.all, Filling, Ty.U32, Value, False, Site));

            function Minus
              (Value : IR.Value_Id; Bias : Ty.Magnitude)
              return IR.Value_Id
              is (IR.Emit_Binary
                    (Unit.all, Filling, IR.Subtract, Value, Literal (Bias),
                     Ty.U32, Site));

            function Times
              (Value : IR.Value_Id; Factor : Ty.Magnitude)
              return IR.Value_Id
              is (IR.Emit_Binary
                    (Unit.all, Filling, IR.Multiply, Value,
                     Literal (Factor), Ty.U32, Site));

            function Plus
              (Left, Right : IR.Value_Id) return IR.Value_Id
              is (IR.Emit_Binary
                    (Unit.all, Filling, IR.Add, Left, Right, Ty.U32, Site));

            procedure Keep (Value : IR.Value_Id; Width : Ty.Magnitude) is
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Element_Slot, Value, Site);
               IR.Emit_Store
                 (Unit.all, Filling, Text_Width_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, Width, False, Site), Site);
            end Keep;

            --  A foreign cstring promises an accessible first NUL, not
            --  prevalidated encoding.  Traversal therefore validates the
            --  one scalar it is about to decode.  Continuations are fetched
            --  in order: a NUL fails its range before a later byte can be
            --  read, so malformed input never causes a read past the first
            --  terminator.  This explicit trap remains inside unchecked.
            procedure Validate_C_String_Scalar (Lead : IR.Value_Id) is
               Lead_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
               One : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Non_ASCII : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Class_Two : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Two : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_E0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_Not_E0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_ED : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_Normal : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_Tail : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_Third : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_F0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_Not_F0 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_F4 : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_Normal : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_Tail_Two : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_Third : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_Fourth : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Invalid : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Done : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);

               function Lead_Is
                 (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                  return IR.Value_Id;
               procedure Require_Range
                 (Value : IR.Value_Id;
                  Lower, Upper : Ty.Magnitude;
                  Success : IR.Block_Id);

               function Lead_Is
                 (Op : IR.Comparison_Kind; Value : Ty.Magnitude)
                  return IR.Value_Id
               is
               begin
                  return IR.Emit_Binary
                    (Unit.all, Filling, Op,
                     IR.Emit_Load (Unit.all, Filling, Lead_Slot, Site),
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.U8, Value, False, Site),
                     Ty.Bool, Site);
               end Lead_Is;

               procedure Require_Range
                 (Value : IR.Value_Id;
                  Lower, Upper : Ty.Magnitude;
                  Success : IR.Block_Id)
               is
                  Saved : constant IR.Slot_Id := IR.Add_Slot
                    (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
                  Test_Upper : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Inside);
               begin
                  IR.Emit_Store (Unit.all, Filling, Saved, Value, Site);
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Greater_Or_Equal,
                        IR.Emit_Load (Unit.all, Filling, Saved, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U8, Lower, False, Site),
                        Ty.Bool, Site),
                     Test_Upper, Invalid, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
                  Open (Test_Upper);
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Less_Or_Equal,
                        IR.Emit_Load (Unit.all, Filling, Saved, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U8, Upper, False, Site),
                        Ty.Bool, Site),
                     Success, Invalid, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end Require_Range;
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Lead_Slot, Lead, Site);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#80#),
                  One, Non_ASCII, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (One);
               Close_With_Jump (Done, Site);

               Open (Non_ASCII);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#C2#),
                  Invalid, Class_Two, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Class_Two);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#E0#),
                  Two, Three, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Two);
               Require_Range
                 (Text_Unit_At (1), 16#80#, 16#BF#, Done);

               Open (Three);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Than, 16#F0#),
                  Three_Not_E0, Four, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Three_Not_E0);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#E0#),
                  Three_E0, Three_Tail, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Three_E0);
               Require_Range
                 (Text_Unit_At (1), 16#A0#, 16#BF#, Three_Third);

               Open (Three_Tail);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#ED#),
                  Three_ED, Three_Normal, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Three_ED);
               Require_Range
                 (Text_Unit_At (1), 16#80#, 16#9F#, Three_Third);

               Open (Three_Normal);
               Require_Range
                 (Text_Unit_At (1), 16#80#, 16#BF#, Three_Third);

               Open (Three_Third);
               Require_Range
                 (Text_Unit_At (2), 16#80#, 16#BF#, Done);

               Open (Four);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Less_Or_Equal, 16#F4#),
                  Four_Not_F0, Invalid, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Four_Not_F0);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#F0#),
                  Four_F0, Four_Tail_Two, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Four_Tail_Two);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Is (IR.Equal_To, 16#F4#),
                  Four_F4, Four_Normal, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Four_F0);
               Require_Range
                 (Text_Unit_At (1), 16#90#, 16#BF#, Four_Third);
               Open (Four_F4);
               Require_Range
                 (Text_Unit_At (1), 16#80#, 16#8F#, Four_Third);
               Open (Four_Normal);
               Require_Range
                 (Text_Unit_At (1), 16#80#, 16#BF#, Four_Third);

               Open (Four_Third);
               Require_Range
                 (Text_Unit_At (2), 16#80#, 16#BF#, Four_Fourth);
               Open (Four_Fourth);
               Require_Range
                 (Text_Unit_At (3), 16#80#, 16#BF#, Done);

               Open (Invalid);
               declare
                  Traps : constant IR.Value_Id := IR.Emit_Range_Check
                    (Unit.all, Filling,
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.U8, 1, False, Site),
                     Ty.U8, 0, 0, Site);
               begin
                  pragma Unreferenced (Traps);
                  Close_With_Jump (Done, Site);
               end;

               Open (Done);
            end Validate_C_String_Scalar;
         begin
            if Collection_View = Ty.C_String_View then
               Validate_C_String_Scalar (Text_Unit_At (0));
            end if;

            if Collection_View = Ty.Utf16_View then
               declare
                  Lead_Slot : constant IR.Slot_Id := IR.Add_Slot
                    (Unit.all, Filling, Ty.U16, Res.No_Declaration, Site);
                  Maybe_High : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Inside);
                  Pair : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Inside);
                  Single : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Inside);
                  Join : constant IR.Block_Id :=
                    Fresh (Of_Tree, Node, Inside);
                  Lead : constant IR.Value_Id := Text_Unit_At (0);
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Lead_Slot, Lead, Site);
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Less_Than,
                        IR.Emit_Load
                          (Unit.all, Filling, Lead_Slot, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U16, 16#D800#, False, Site),
                        Ty.Bool, Site),
                     Single, Maybe_High, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;

                  Open (Maybe_High);
                  IR.Emit_Branch
                    (Unit.all, Filling,
                     IR.Emit_Binary
                       (Unit.all, Filling, IR.Less_Than,
                        IR.Emit_Load
                          (Unit.all, Filling, Lead_Slot, Site),
                        IR.Emit_Number
                          (Unit.all, Filling, Ty.U16, 16#DC00#, False, Site),
                        Ty.Bool, Site),
                     Pair, Single, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;

                  Open (Single);
                  Keep
                    (As_U32
                       (IR.Emit_Load
                          (Unit.all, Filling, Lead_Slot, Site)), 1);
                  Close_With_Jump (Join, Site);

                  Open (Pair);
                  declare
                     High : constant IR.Value_Id := Minus
                       (As_U32
                          (IR.Emit_Load
                             (Unit.all, Filling, Lead_Slot, Site)),
                        16#D800#);
                     Low : constant IR.Value_Id := Minus
                       (As_U32 (Text_Unit_At (1)), 16#DC00#);
                  begin
                     Keep
                       (Plus
                          (Literal (16#10000#),
                           Plus (Times (High, 16#400#), Low)), 2);
                  end;
                  Close_With_Jump (Join, Site);

                  Open (Join);
               end;
               return;
            end if;

            declare
               Lead_Slot : constant IR.Slot_Id := IR.Add_Slot
                 (Unit.all, Filling, Ty.U8, Res.No_Declaration, Site);
               Non_ASCII : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Test_Three : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Test_Four : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               One_Byte : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Two_Bytes : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Three_Bytes : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Four_Bytes : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Join : constant IR.Block_Id :=
                 Fresh (Of_Tree, Node, Inside);
               Lead : constant IR.Value_Id := Text_Unit_At (0);

               function Lead_Below
                 (Limit : Ty.Magnitude) return IR.Value_Id;

               function Lead_Below
                 (Limit : Ty.Magnitude) return IR.Value_Id is
               begin
                  return IR.Emit_Binary
                    (Unit.all, Filling, IR.Less_Than,
                     IR.Emit_Load (Unit.all, Filling, Lead_Slot, Site),
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.U8, Limit, False, Site),
                     Ty.Bool, Site);
               end Lead_Below;
            begin
               IR.Emit_Store (Unit.all, Filling, Lead_Slot, Lead, Site);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Below (16#80#),
                  One_Byte, Non_ASCII, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Non_ASCII);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Below (16#E0#),
                  Two_Bytes, Test_Three, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Test_Three);
               IR.Emit_Branch
                 (Unit.all, Filling, Lead_Below (16#F0#),
                  Three_Bytes, Test_Four, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Test_Four);
               Close_With_Jump (Four_Bytes, Site);

               Open (One_Byte);
               Keep
                 (As_U32
                    (IR.Emit_Load
                       (Unit.all, Filling, Lead_Slot, Site)), 1);
               Close_With_Jump (Join, Site);

               Open (Two_Bytes);
               Keep
                 (Plus
                    (Times
                       (Minus
                          (As_U32
                             (IR.Emit_Load
                                (Unit.all, Filling, Lead_Slot, Site)),
                           16#C0#), 16#40#),
                     Minus (As_U32 (Text_Unit_At (1)), 16#80#)), 2);
               Close_With_Jump (Join, Site);

               Open (Three_Bytes);
               Keep
                 (Plus
                    (Times
                       (Minus
                          (As_U32
                             (IR.Emit_Load
                                (Unit.all, Filling, Lead_Slot, Site)),
                           16#E0#), 16#1000#),
                     Plus
                       (Times
                          (Minus
                             (As_U32 (Text_Unit_At (1)), 16#80#), 16#40#),
                        Minus
                          (As_U32 (Text_Unit_At (2)), 16#80#))), 3);
               Close_With_Jump (Join, Site);

               Open (Four_Bytes);
               Keep
                 (Plus
                    (Times
                       (Minus
                          (As_U32
                             (IR.Emit_Load
                                (Unit.all, Filling, Lead_Slot, Site)),
                           16#F0#), 16#40000#),
                     Plus
                       (Times
                          (Minus
                             (As_U32 (Text_Unit_At (1)), 16#80#),
                           16#1000#),
                        Plus
                          (Times
                             (Minus
                                (As_U32 (Text_Unit_At (2)), 16#80#),
                              16#40#),
                           Minus
                             (As_U32 (Text_Unit_At (3)), 16#80#)))), 4);
               Close_With_Jump (Join, Site);

               Open (Join);
            end;
         end Decode_Text_Item;
      begin
         if Is_Storage_Collection then
            declare
               Source : constant Syn.Node_Id :=
                 Syn.Traversal_Lower (Of_Tree, Node);
               Base : IR.Value_Id;
               Length : IR.Value_Id;
            begin
               if Type_At (Of_Tree, Source) = Ty.Slice_Value then
                  declare
                     Parts : constant Slice_Values :=
                       Lower_Slice (Of_Tree, Source, Scope);
                  begin
                     Base := Parts.Base;
                     Length := Parts.Length;
                  end;
                  Element_Shape := Slice_Shape (Of_Tree, Source);
               else
                  declare
                     Place : Stored_Place;
                  begin
                     if Syn.Kind (Of_Tree, Source)
                       in Syn.Name_Reference | Syn.Member_Selection
                          | Syn.Element_Index
                     then
                        Place := Lower_Stored_Place (Of_Tree, Source, Scope);
                     else
                        Place.Place :=
                          (Kind => IR.Frame_Slot,
                           Slot => Add_Value_Temporary (Of_Tree, Source));
                        Lower_Stored_Expression
                          (Of_Tree, Source, Scope, Place.Place.Slot);
                     end if;
                     if Current = IR.No_Block then
                        return;
                     end if;
                     Base := IR.Emit_Storage_Address
                       (Unit.all, Filling, Place.Place, Site,
                        Field  => Place.Base,
                        Nested => Stored_Steps (Place));
                  end;
                  Length := IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize,
                     Ty.Magnitude
                       (Landin.Checking.Array_Length
                          (Types.all, Of_Tree, Source)),
                     False, Site);
                  Element_Shape := Neutral_Element (Of_Tree, Source);
               end if;
               if Current = IR.No_Block then
                  return;
               end if;

               Base_Slot := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Length_Slot := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Counter_Slot :=
                 (if Index_Slot /= IR.No_Slot then Index_Slot
                  else IR.Add_Slot
                    (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site));
               Address_Slot := IR.Add_Address_Slot
                 (Unit.all, Filling, Element_Shape, Site);
               IR.Emit_Store (Unit.all, Filling, Base_Slot, Base, Site);
               IR.Emit_Store (Unit.all, Filling, Length_Slot, Length, Site);
               IR.Emit_Store
                 (Unit.all, Filling, Counter_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
               Aliases (Declared (Element_Id)) :=
                 (Active        => True,
                  Source        => (Kind => IR.Runtime_Address,
                                    Address => Address_Slot),
                  Field         => 0,
                  Subject       => Syn.No_Node,
                  Which         => 0,
                  Payload_Field => 0);
               IR.Note_Source_Alias
                 (Unit.all, Filling,
                  (Binding => Element_Id,
                   Site => Site_Of (Of_Tree, Element_Node),
                   Place => (Kind => IR.Runtime_Address,
                             Address => Address_Slot),
                   Field => 0, Initialized_On_Entry => True),
                  IR.No_Path_Steps);
            end;
         elsif Is_Text then
            declare
               Source : constant Syn.Node_Id := Collection_Source;
               Base : IR.Value_Id;
               Length : IR.Value_Id := IR.No_Value;
            begin
               --  D184 evaluates and retains the complete source before its
               --  intrinsic first provider establishes cursor zero.  The
               --  two length-bearing identities keep both carrier words;
               --  cstring keeps only its pointer-shaped identity.
               if Collection_View = Ty.C_String_View then
                  Base := Lower_Expression (Of_Tree, Source, Scope);
                  Element_Shape :=
                    (Kind => IR.Scalar_Field_Shape, Element => Ty.U8,
                     Length => 1, others => <>);
               else
                  declare
                     Parts : constant Slice_Values :=
                       Lower_Slice (Of_Tree, Source, Scope);
                  begin
                     Base := Parts.Base;
                     Length := Parts.Length;
                  end;
                  Element_Shape := Slice_Shape (Of_Tree, Source);
               end if;
               if Current = IR.No_Block then
                  return;
               end if;

               Base_Slot := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               IR.Emit_Store (Unit.all, Filling, Base_Slot, Base, Site);
               if Collection_View /= Ty.C_String_View then
                  Length_Slot := IR.Add_Slot
                    (Unit.all, Filling, Ty.Usize,
                     Res.No_Declaration, Site);
                  IR.Emit_Store
                    (Unit.all, Filling, Length_Slot, Length, Site);
               end if;

               Cursor_Slot := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Text_Width_Slot := IR.Add_Slot
                 (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
               Counter_Slot :=
                 (if Index_Slot /= IR.No_Slot then Index_Slot
                  else IR.Add_Slot
                    (Unit.all, Filling, Ty.Usize,
                     Res.No_Declaration, Site));
               IR.Emit_Store
                 (Unit.all, Filling, Cursor_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
               IR.Emit_Store
                 (Unit.all, Filling, Counter_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
            end;
         elsif Is_Evidence then
            declare
               Source : constant Syn.Node_Id :=
                 Syn.Traversal_Lower (Of_Tree, Node);
               First_Signature : constant Landin.Checking.Signature_Id :=
                 Provider_Signature (1);
               Made : IR.Value_Id;
            begin
               --  D180: retain one source value for every evidence call.
               --  A struct and an `any C` both use their ordinary stored
               --  copy shape; the latter remains a data/evidence pair and
               --  is never interpreted as a slice base and length.
               Source_Slot := Add_Value_Temporary (Of_Tree, Source);
               if Type_At (Of_Tree, Source) = Ty.Aggregate
                 and then Syn.Kind (Of_Tree, Source)
                   in Syn.Name_Reference | Syn.Member_Selection
                      | Syn.Element_Index
               then
                  declare
                     Nominal : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of
                         (Types.all, Of_Tree, Source);
                     Shape : constant IR.Field_Shape :=
                       Neutral_Body (Nominal);
                     From : constant Stored_Place :=
                       Lower_Stored_Place (Of_Tree, Source, Scope);
                     Into : constant Stored_Place :=
                       (Place => (Kind => IR.Frame_Slot, Slot => Source_Slot),
                        Base => 0,
                        Steps => Stored_Path_Vectors.Empty_Vector);
                  begin
                     IR.Emit_Array_Copy
                       (Unit.all, Filling,
                        Addressed_Storage (From, Shape, Site),
                        Addressed_Storage (Into, Shape, Site), Site);
                  end;
               else
                  Lower_Stored_Expression
                    (Of_Tree, Source, Scope, Source_Slot);
               end if;
               if Current = IR.No_Block then
                  return;
               end if;

               Cursor_Part := Landin.Checking.Nth_Signature_Result
                 (Types.all, First_Signature, 1);
               Cursor_Slot := Add_Part_Slot (Cursor_Part);
               Made := Call_Entry
                 (1, Cursor_Part, Cursor_Slot, With_Cursor => False);
               if not Is_Stored (Cursor_Part) then
                  IR.Emit_Store
                    (Unit.all, Filling, Cursor_Slot, Made, Site);
               end if;

               Counter_Slot :=
                 (if Index_Slot /= IR.No_Slot then Index_Slot
                  else IR.Add_Slot
                    (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site));
               IR.Emit_Store
                 (Unit.all, Filling, Counter_Slot,
                  IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
            end;
         end if;

         if Is_Range then
            declare
               Lower : constant IR.Value_Id :=
                 Lower_Expression
                   (Of_Tree, Syn.Traversal_Lower (Of_Tree, Node), Scope);
               Upper : IR.Value_Id;
            begin
               if Current = IR.No_Block then
                  return;
               end if;
               IR.Emit_Store
                 (Unit.all, Filling, Element_Slot, Lower, Site);
               Upper := Lower_Expression
                 (Of_Tree, Syn.Traversal_Upper (Of_Tree, Node), Scope);
               if Current = IR.No_Block then
                  return;
               end if;
               Upper_Slot := IR.Add_Slot
                 (Unit.all, Filling, Range_Type, Res.No_Declaration, Site);
               IR.Emit_Store
                 (Unit.all, Filling, Upper_Slot, Upper, Site);
               if Index_Slot /= IR.No_Slot then
                  IR.Emit_Store
                    (Unit.all, Filling, Index_Slot,
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.Usize, 0, False, Site), Site);
               end if;
            end;
         end if;

         Close_With_Jump ((if Is_For then Entry_Block else Head), Site);
         if Is_For then
            --  The step is `continue`'s target.  Keep it in the verified CFG
            --  even when this particular body has no fallthrough or
            --  continue edge; the false arm is structural and never taken.
            Open (Entry_Block);
            declare
               Never : constant IR.Value_Id :=
                 IR.Emit_Truth (Unit.all, Filling, False, Site);
            begin
               IR.Emit_Branch
                 (Unit.all, Filling, Never, Step_Block, Head, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;
            end;
         end if;
         IR.Set_Loop_Depth (Unit.all, Filling, Enclosing_Depth + 1);
         Open (Head);
         if Is_While then
            declare
               Test : constant IR.Value_Id :=
                 Lower_Condition
                   (Of_Tree, Syn.Condition_Of (Of_Tree, Node), Scope);
            begin
               if Current /= IR.No_Block then
                  IR.Emit_Branch
                    (Unit.all, Filling, Test, Body_Block, Natural_Exit, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end if;
            end;
         elsif Is_Storage_Collection then
            declare
               Position : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Counter_Slot, Site);
               Count : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Length_Slot, Site);
               Test : constant IR.Value_Id :=
                 IR.Emit_Binary
                   (Unit.all, Filling, IR.Less_Than,
                    Position, Count, Ty.Bool, Site);
            begin
               IR.Emit_Branch
                 (Unit.all, Filling, Test, Body_Block, Natural_Exit, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;
            end;
         elsif Is_Text then
            declare
               Ended : IR.Value_Id;
            begin
               --  D184's at_end provider compares a length-bearing cursor
               --  with its retained code-unit length.  cstring instead
               --  observes the first NUL and never exposes that terminator
               --  as an Item.
               if Collection_View = Ty.C_String_View then
                  Ended := IR.Emit_Binary
                    (Unit.all, Filling, IR.Equal_To, Text_Unit_At (0),
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.U8, 0, False, Site),
                     Ty.Bool, Site);
               else
                  Ended := IR.Emit_Binary
                    (Unit.all, Filling, IR.Equal_To,
                     IR.Emit_Load
                       (Unit.all, Filling, Cursor_Slot, Site),
                     IR.Emit_Load
                       (Unit.all, Filling, Length_Slot, Site),
                     Ty.Bool, Site);
               end if;
               IR.Emit_Branch
                 (Unit.all, Filling, Ended,
                  Natural_Exit, Body_Block, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;
            end;
         elsif Is_Evidence then
            declare
               At_End_Signature : constant
                 Landin.Checking.Signature_Id := Provider_Signature (2);
               At_End_Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Result
                   (Types.all, At_End_Signature, 1);
               Ended : constant IR.Value_Id := Call_Entry
                 (2, At_End_Part, IR.No_Slot, With_Cursor => True);
            begin
               IR.Emit_Branch
                 (Unit.all, Filling, Ended, Natural_Exit, Body_Block, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;
            end;
         elsif Is_For then
            declare
               Current_Value : constant IR.Value_Id :=
                 IR.Emit_Load
                   (Unit.all, Filling, Element_Slot, Site);
               Last_Value : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Upper_Slot, Site);
               Test : constant IR.Value_Id :=
                 IR.Emit_Binary
                   (Unit.all, Filling,
                    (if Syn.Traversal_Is_Inclusive (Of_Tree, Node)
                     then IR.Less_Or_Equal else IR.Less_Than),
                    Current_Value, Last_Value, Ty.Bool, Site);
            begin
               IR.Emit_Branch
                 (Unit.all, Filling, Test, Body_Block, Natural_Exit, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;
            end;
         else
            Close_With_Jump (Body_Block, Site);
         end if;

         declare
            Frame : Loop_Entry :=
              (Label        => Syn.Name (Of_Tree, Node),
               Head         => (if Is_For then Step_Block else Head),
               Exit_Block   => Exit_Block,
               Cleanup_Base => Natural (Cleanup_Stack.Length),
               Value_Destination => Destination,
               Value_Destination_Field => Destination_Field,
               Value_Destination_Path =>
                 Stored_Path_Vectors.Empty_Vector);
         begin
            for Step of Destination_Path loop
               Frame.Value_Destination_Path.Append (Step);
            end loop;
            Loop_Stack.Append (Frame);
         end;
         Open (Body_Block);
         if Is_Storage_Collection then
            --  The element's address for this iteration.  The bound check
            --  is structural: the head already proved the counter is below
            --  the length, and the verifier sees an ordinary element
            --  address of the storage.
            declare
               Position : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Counter_Slot, Site);
               Address : constant IR.Value_Id :=
                 IR.Emit_Slice_Address
                   (Unit.all, Filling,
                    IR.Emit_Load (Unit.all, Filling, Base_Slot, Site),
                    IR.Emit_Load (Unit.all, Filling, Length_Slot, Site),
                    Position, Position, Element_Shape, True, Site);
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Address_Slot, Address, Site);
            end;
         elsif Is_Text then
            --  The intrinsic item provider decodes one complete Unicode
            --  scalar into the immutable copied `u32` loop binding.  Its
            --  physical width is retained privately for next.
            Decode_Text_Item;
         elsif Is_Evidence then
            declare
               Item_Signature : constant Landin.Checking.Signature_Id :=
                 Provider_Signature (3);
               Item_Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Result
                   (Types.all, Item_Signature, 1);
               Made : constant IR.Value_Id := Call_Entry
                 (3, Item_Part, Element_Slot, With_Cursor => True);
            begin
               --  [1160]: item hands out a value.  Stored answers are
               --  written directly into the binding's own slot; scalar
               --  answers cross the same explicit store as a source call.
               if not Is_Stored (Item_Part) then
                  IR.Emit_Store
                    (Unit.all, Filling, Element_Slot, Made, Site);
               end if;
            end;
         end if;
         Lower_Statements (Of_Tree, Runs, Inside, Result);
         if Current /= IR.No_Block then
            Close_With_Jump
              ((if Is_For then Step_Block else Head), Site);
         end if;

         if Is_Storage_Collection then
            Open (Step_Block);
            declare
               Position : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Counter_Slot, Site);
               One : constant IR.Value_Id :=
                 IR.Emit_Number
                   (Unit.all, Filling, Ty.Usize, 1, False, Site);
               Next_Position : constant IR.Value_Id :=
                 IR.Emit_Binary
                   (Unit.all, Filling, IR.Add, Position, One, Ty.Usize, Site);
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Counter_Slot, Next_Position, Site);
               Close_With_Jump (Head, Site);
            end;
         elsif Is_Text then
            Open (Step_Block);
            declare
               Cursor : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Cursor_Slot, Site);
               Width : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Text_Width_Slot, Site);
               Index : constant IR.Value_Id :=
                 IR.Emit_Load (Unit.all, Filling, Counter_Slot, Site);
            begin
               --  D184's next provider advances by the decoded scalar's
               --  physical code-unit width; the optional loop index counts
               --  Items and therefore advances exactly once per next call.
               IR.Emit_Store
                 (Unit.all, Filling, Cursor_Slot,
                  IR.Emit_Binary
                    (Unit.all, Filling, IR.Add,
                     Cursor, Width, Ty.Usize, Site), Site);
               IR.Emit_Store
                 (Unit.all, Filling, Counter_Slot,
                  IR.Emit_Binary
                    (Unit.all, Filling, IR.Add, Index,
                     IR.Emit_Number
                       (Unit.all, Filling, Ty.Usize, 1, False, Site),
                     Ty.Usize, Site), Site);
               Close_With_Jump (Head, Site);
            end;
         elsif Is_Evidence then
            Open (Step_Block);
            declare
               Next_Slot : constant IR.Slot_Id :=
                 Add_Part_Slot (Cursor_Part);
               Made : constant IR.Value_Id := Call_Entry
                 (4, Cursor_Part, Next_Slot, With_Cursor => True);
            begin
               if Is_Stored (Cursor_Part) then
                  --  The next provider receives the old cursor by value.
                  --  Keep its destination separate until the call returns,
                  --  then copy the complete retained Cur identity back.
                  Copy_Part (Next_Slot, Cursor_Slot, Cursor_Part);
               else
                  IR.Emit_Store
                    (Unit.all, Filling, Cursor_Slot, Made, Site);
               end if;

               declare
                  Current_Index : constant IR.Value_Id :=
                    IR.Emit_Load (Unit.all, Filling, Counter_Slot, Site);
                  One : constant IR.Value_Id := IR.Emit_Number
                    (Unit.all, Filling, Ty.Usize, 1, False, Site);
                  Next_Index : constant IR.Value_Id := IR.Emit_Binary
                    (Unit.all, Filling, IR.Add,
                     Current_Index, One, Ty.Usize, Site);
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Counter_Slot, Next_Index, Site);
               end;
               Close_With_Jump (Head, Site);
            end;
         elsif Is_For then
            Open (Step_Block);
            if Syn.Traversal_Is_Inclusive (Of_Tree, Node) then
               declare
                  Current_Value : constant IR.Value_Id :=
                    IR.Emit_Load
                      (Unit.all, Filling, Element_Slot, Site);
                  Last_Value : constant IR.Value_Id :=
                    IR.Emit_Load
                      (Unit.all, Filling, Upper_Slot, Site);
                  Finished : constant IR.Value_Id :=
                    IR.Emit_Binary
                      (Unit.all, Filling, IR.Equal_To,
                       Current_Value, Last_Value, Ty.Bool, Site);
               begin
                  IR.Emit_Branch
                    (Unit.all, Filling, Finished, Natural_Exit,
                     Increment_Block, Site);
                  IR.Leave_Block (Unit.all, Filling);
                  Current := IR.No_Block;
               end;
               Open (Increment_Block);
            end if;

            declare
               Current_Value : constant IR.Value_Id :=
                 IR.Emit_Load
                   (Unit.all, Filling, Element_Slot, Site);
               One : constant IR.Value_Id :=
                 IR.Emit_Number
                   (Unit.all, Filling, Range_Type, 1, False, Site);
               Next_Value : constant IR.Value_Id :=
                 IR.Emit_Binary
                   (Unit.all, Filling, IR.Add,
                    Current_Value, One, Range_Type, Site);
            begin
               IR.Emit_Store
                 (Unit.all, Filling, Element_Slot, Next_Value, Site);
               if Index_Slot /= IR.No_Slot then
                  declare
                     Current_Index : constant IR.Value_Id :=
                       IR.Emit_Load
                         (Unit.all, Filling, Index_Slot, Site);
                     Index_One : constant IR.Value_Id :=
                       IR.Emit_Number
                         (Unit.all, Filling, Ty.Usize, 1, False, Site);
                     Next_Index : constant IR.Value_Id :=
                       IR.Emit_Binary
                         (Unit.all, Filling, IR.Add,
                          Current_Index, Index_One, Ty.Usize, Site);
                  begin
                     IR.Emit_Store
                       (Unit.all, Filling, Index_Slot, Next_Index, Site);
                  end;
               end if;
               Close_With_Jump (Head, Site);
            end;
         end if;

         IR.Set_Loop_Depth (Unit.all, Filling, Enclosing_Depth);
         if Has_Complete then
            declare
               Complete_Node : constant Syn.Node_Id :=
                 Syn.Complete_Body (Of_Tree, Node);
               Complete_Scope : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Complete_Node);
            begin
               Open (Complete_Block);
               Lower_Statements
                 (Of_Tree, Complete_Node, Complete_Scope, Result);
               if Current /= IR.No_Block then
                  Close_With_Jump (Exit_Block, Site);
               end if;
            end;
         end if;

         Loop_Stack.Delete_Last;

         if Has_Exit then
            Open (Exit_Block);
         end if;
      end Lower_Loop;

      procedure Lower_Loop_Transfer
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id)
      is
         Site : constant Landin.Provenance.Origin := Site_Of (Of_Tree, Node);
         Frame : constant Loop_Entry := Transfer_Loop (Of_Tree, Node);
         Target : constant IR.Block_Id :=
           (if Syn.Kind (Of_Tree, Node) = Syn.Break_Statement
            then Frame.Exit_Block else Frame.Head);

         procedure Transfer;

         procedure Transfer is
         begin
            if Syn.Kind (Of_Tree, Node) = Syn.Break_Statement
              and then Syn.Transfer_Value (Of_Tree, Node) /= Syn.No_Node
            then
               declare
                  Destination_Path : IR.Path_Step_Array
                    (1 .. Natural (Frame.Value_Destination_Path.Length));
               begin
                  for Index in Destination_Path'Range loop
                     Destination_Path (Index) :=
                       Frame.Value_Destination_Path (Index);
                  end loop;
                  Lower_Statements
                    (Of_Tree, Syn.No_Node, Scope, Active_Result,
                     Destination => Frame.Value_Destination,
                     Destination_Field => Frame.Value_Destination_Field,
                     Destination_Path => Destination_Path,
                     Direct_Value => Syn.Transfer_Value (Of_Tree, Node));
               end;
            end if;

            Emit_Cleanups
              (Of_Tree, Frame.Cleanup_Base + 1,
               Cleanup.Structured_Transfer);
            if Current /= IR.No_Block then
               Close_With_Jump (Target, Site);
            end if;
         end Transfer;
      begin
         if Syn.Condition_Of (Of_Tree, Node) = Syn.No_Node then
            Transfer;
         else
            declare
               Test : constant IR.Value_Id :=
                 Lower_Expression
                   (Of_Tree, Syn.Condition_Of (Of_Tree, Node), Scope);
            begin
               if Current /= IR.No_Block then
                  declare
                     Goes : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Stays : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                  begin
                     IR.Emit_Branch
                       (Unit.all, Filling, Test, Goes, Stays, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;
                     Open (Goes);
                     Transfer;
                     Open (Stays);
                  end;
               end if;
            end;
         end if;
      end Lower_Loop_Transfer;

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
         Destination_Path : IR.Path_Step_Array := IR.No_Path_Steps;
         Direct_Value : Syn.Node_Id := Syn.No_Node)
      is
         Last_Statement : constant Natural :=
           (if Direct_Value /= Syn.No_Node
            then 0 else Syn.Statement_Count (Of_Tree, Block));
         Has_Value : constant Boolean :=
           Direct_Value /= Syn.No_Node
           or else Syn.Block_Value (Of_Tree, Block) /= Syn.No_Node;
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
                  then (if Direct_Value /= Syn.No_Node
                        then Direct_Value
                        else Syn.Block_Value (Of_Tree, Block))
                  else Syn.Nth_Statement (Of_Tree, Block, Which));
               Site : constant Landin.Provenance.Origin :=
                 Site_Of (Of_Tree, Stmt);

               --  [0410] evaluates a destination place before its value.
               --  Reference storage retains the complete checked address;
               --  other computed places carry their index through the
               --  read-modify-write without evaluating it again.
               function Reference_Address_For
                 (Place : Syn.Node_Id) return IR.Slot_Id;

               function Index_For (Place : Syn.Node_Id) return IR.Value_Id;

               function Read_Place
                 (Place : Syn.Node_Id;
                  Index : IR.Value_Id;
                  Address_Slot : IR.Slot_Id := IR.No_Slot)
                  return IR.Value_Id;

               --  [1900]: reference writeback uses its retained address;
               --  named storage keeps its ordinary slot or datum operation.
               procedure Write
                 (Place : Syn.Node_Id;
                  Value : IR.Value_Id;
                  Index : IR.Value_Id := IR.No_Value;
                  Address_Slot : IR.Slot_Id := IR.No_Slot);

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
                                 declare
                                    Neutral : constant IR.Field_Shape :=
                                      Neutral_Shape (Shape);
                                    Address : constant IR.Storage :=
                                      Addressed_Storage
                                        (Stored_At
                                           (Source, From_Field, From_Steps),
                                         Neutral, Site);
                                 begin
                                    Taken := IR.Emit_Load_Indirect
                                      (Unit.all, Filling,
                                       Address.Address, Site);
                                 end;
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
                                 Store_Shaped_Scalar
                                   (Stored_At
                                      (Destination, Into_Field, Into_Steps),
                                    Neutral_Shape (Shape), Taken, Site);
                           end case;
                        end;

                     when Landin.Checking.Reference_Field =>
                        declare
                           Shape : constant Landin.Checking.Field_Shape :=
                             Landin.Checking.Field_Shape_Of
                               (Types.all, Wrote, Field);
                        begin
                           if Landin.Checking.Descriptor_Of
                             (Types.all, Shape.Reference).Kind
                               in Ty.Slice_Value | Ty.Any_Value
                           then
                              IR.Emit_Array_Copy
                                (Unit.all, Filling,
                                 Source => Source,
                                 Destination => Destination,
                                 Site => Site,
                                 Source_Field => From_Field,
                                 Source_Nested => From_Steps,
                                 Destination_Field => Into_Field,
                                 Destination_Nested => Into_Steps);
                           else
                              declare
                                 Taken : IR.Value_Id;
                              begin
                                 case Source.Kind is
                                    when IR.Module_Datum =>
                                       Taken := IR.Emit_Load_Field
                                         (Unit.all, Filling, Source.Datum,
                                          Leaf_Base
                                            (From_Field, From_Steps),
                                          Ty.Usize, Site,
                                          Nested => Leaf_Steps
                                            (From_Field, From_Steps));
                                    when IR.Frame_Slot =>
                                       Taken := IR.Emit_Load_Slot_Field
                                         (Unit.all, Filling, Source.Slot,
                                          Leaf_Base
                                            (From_Field, From_Steps),
                                          Ty.Usize, Site,
                                          Nested => Leaf_Steps
                                            (From_Field, From_Steps));
                                    when IR.Runtime_Address =>
                                       declare
                                          Address : constant IR.Storage :=
                                            Addressed_Storage
                                              (Stored_At (Source, From_Field,
                                                          From_Steps),
                                               Neutral_Shape (Shape), Site);
                                       begin
                                          Taken := IR.Emit_Load_Indirect
                                            (Unit.all, Filling,
                                             Address.Address, Site);
                                       end;
                                 end case;
                                 case Destination.Kind is
                                    when IR.Module_Datum =>
                                       IR.Emit_Store_Field
                                         (Unit.all, Filling,
                                          Destination.Datum,
                                          Leaf_Base
                                            (Into_Field, Into_Steps),
                                          Taken, Site,
                                          Nested => Leaf_Steps
                                            (Into_Field, Into_Steps));
                                    when IR.Frame_Slot =>
                                       IR.Emit_Store_Slot_Field
                                         (Unit.all, Filling,
                                          Destination.Slot,
                                          Leaf_Base
                                            (Into_Field, Into_Steps),
                                          Taken, Site,
                                          Nested => Leaf_Steps
                                            (Into_Field, Into_Steps));
                                    when IR.Runtime_Address =>
                                       Store_Shaped_Scalar
                                         (Stored_At
                                            (Destination, Into_Field,
                                             Into_Steps),
                                          Neutral_Shape (Shape), Taken, Site);
                                 end case;
                              end;
                           end if;
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
                    or else Has_Reference_Storage (Of_Tree, Source_Node)
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
                     when Ty.Scalar_Name | Ty.Function_Value
                        | Ty.Pointer_Value | Ty.Atom_Value =>
                        declare
                           Held : constant Ty.Scalar_Name :=
                             (if Part.Kind in Ty.Function_Value
                                                | Ty.Pointer_Value
                              then Ty.Usize
                              elsif Part.Kind = Ty.Atom_Value
                              then Ty.U32 else Ty.Scalar_Name (Part.Kind));
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

                     when Ty.Fixed_Array | Ty.Slice_Value | Ty.Any_Value =>
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
                  Steps : constant IR.Path_Step_Array :=
                    (if Variant_Payload_Field = 0 then Path
                     else Payload_Steps
                       (Path, Positive (Variant_Case),
                        Positive (Variant_Payload_Field)));
                  Shape : constant IR.Field_Shape :=
                    Neutral_Value_Shape (Of_Tree, Value);
               begin
                  Write_Shaped_Value
                    (Of_Tree, Value, Scope, Shape,
                     Stored_At (Destination, Field, Steps));
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

                           when Landin.Checking.Reference_Field =>
                              if Landin.Checking.Descriptor_Of
                                (Types.all, Shape.Reference).Kind
                                  = Ty.Pointer_Value
                              then
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
                              else
                                 Write_Array_Value
                                   (Construction_Field_Value
                                      (Of_Tree, Label), Destination,
                                    Base, Path => Steps,
                                    Variant_Case => Which,
                                    Variant_Payload_Field => Payload_Field);
                              end if;

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
                  Shape : constant IR.Field_Shape := Neutral_Body (Wrote);
               begin
                  Write_Shaped_Value
                    (Of_Tree, Literal, Scope, Shape,
                     Stored_At (Destination, Base, Steps));
               end Write_Struct_Literal;

               function Reference_Address_For
                 (Place : Syn.Node_Id) return IR.Slot_Id is
               begin
                  if Current = IR.No_Block
                    or else not
                      (Has_Reference_Storage (Of_Tree, Place)
                       or else
                         (Syn.Kind (Of_Tree, Place)
                            in Syn.Element_Index | Syn.Member_Selection
                          and then
                            (Type_At (Of_Tree, Place)
                               in Ty.Function_Value | Ty.Pointer_Value
                                  | Ty.Atom_Value
                             or else Has_Computed_Index
                               (Of_Tree, Syn.Target_Of (Of_Tree, Place)))))
                  then
                     return IR.No_Slot;
                  end if;
                  declare
                     Reached : constant Stored_Place :=
                       Lower_Stored_Place (Of_Tree, Place, Scope);
                  begin
                     if Current = IR.No_Block then
                        return IR.No_Slot;
                     end if;
                     --  Resolve and check the complete destination before
                     --  its RHS or old value. The address slot survives
                     --  recovery and control-flow joins without a replay.
                     if Reached.Place.Kind = IR.Runtime_Address
                       and then Reached.Base = 0
                       and then Reached.Steps.Is_Empty
                     then
                        return Reached.Place.Address;
                     end if;
                     declare
                        Address : constant IR.Value_Id := IR.Emit_Place_Address
                          (Unit.all, Filling, Reached.Place, Site,
                           Field => Reached.Base,
                           Nested => Stored_Steps (Reached));
                        Slot : constant IR.Slot_Id := IR.Add_Address_Slot
                          (Unit.all, Filling,
                           Neutral_Value_Shape (Of_Tree, Place), Site);
                     begin
                        IR.Emit_Store
                          (Unit.all, Filling, Slot, Address, Site);
                        return Slot;
                     end;
                  end;
               end Reference_Address_For;

               function Index_For (Place : Syn.Node_Id) return IR.Value_Id is
               begin
                  --  Only a directly named flat array has a scalar-field
                  --  shortcut. Nested selections retain their array path.
                  if Has_Reference_Storage (Of_Tree, Place)
                    or else Syn.Kind (Of_Tree, Place) /= Syn.Element_Index
                    or else
                      (Is_Constant_Index (Of_Tree, Place)
                       and then Syn.Kind
                                  (Of_Tree, Syn.Target_Of (Of_Tree, Place))
                                = Syn.Name_Reference
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
                 (Place : Syn.Node_Id;
                  Index : IR.Value_Id;
                  Address_Slot : IR.Slot_Id := IR.No_Slot)
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
                  if Address_Slot /= IR.No_Slot then
                     return IR.Emit_Load_Indirect
                       (Unit.all, Filling, Address_Slot, Site);
                  end if;
                  if Index = IR.No_Value then
                     return Lower_Expression (Of_Tree, Place, Scope);
                  end if;

                  Means := Res.Bound_To (Meanings.all, Of_Tree, Named);
                  if Aliases (Declared (Means)).Active then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                        Element_Path : constant IR.Path_Step_Array :=
                          Alias_Element_Steps
                            (Of_Tree, Alias,
                             Chain_All_Steps (Of_Tree, From));
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
                                 Nested => Element_Path,
                                 Variant_Case =>
                                   (if Element_Path'Length = 0
                                    then Alias.Which else 0),
                                 Variant_Payload_Field =>
                                   (if Element_Path'Length = 0
                                    then Alias.Payload_Field else 0));
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Alias.Source.Slot,
                                 Index, Scalar_At (Of_Tree, Place), Site,
                                 Field => Alias.Field,
                                 Nested => Element_Path,
                                 Variant_Case =>
                                   (if Element_Path'Length = 0
                                    then Alias.Which else 0),
                                 Variant_Payload_Field =>
                                   (if Element_Path'Length = 0
                                    then Alias.Payload_Field else 0));
                           when IR.Runtime_Address =>
                              raise Landin.Compiler_Defect with
                                "a runtime array alias reached scalar read";
                        end case;
                     end;
                  end if;
                  if Res.Sort_Of (Meanings.all, Means) /= Res.Module_Binding
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
                  Index : IR.Value_Id := IR.No_Value;
                  Address_Slot : IR.Slot_Id := IR.No_Slot)
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
                    (if Address_Slot /= IR.No_Slot
                         or else Current = IR.No_Block
                     then Syn.No_Node
                     else Chain_Root
                       (Of_Tree, Chain_Above (Of_Tree, Selected)));
                  Means : constant Res.Declaration_Id :=
                    (if Named = Syn.No_Node then Res.No_Declaration
                     else Res.Bound_To (Meanings.all, Of_Tree, Named));
               begin
                  if Current = IR.No_Block then
                     return;
                  elsif Address_Slot /= IR.No_Slot then
                     IR.Emit_Store_Indirect
                       (Unit.all, Filling, Address_Slot, Value, Site);
                     return;
                  end if;

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
                        Element_Path : constant IR.Path_Step_Array :=
                          Alias_Element_Steps
                            (Of_Tree, Alias,
                             Chain_All_Steps (Of_Tree, Selected));
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
                                    declare
                                       Address : constant IR.Value_Id :=
                                         IR.Emit_Storage_Address
                                           (Unit.all, Filling, Alias.Source,
                                            Site, Index => Index);
                                    begin
                                       IR.Emit_Store_Indirect
                                         (Unit.all, Filling, Address, Value,
                                          Site);
                                    end;
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
                                    --  D160: written through the address
                                    --  a traversal element keeps.
                                    if Alias.Field /= 0 then
                                       raise Landin.Compiler_Defect with
                                         "a runtime alias reached scalar"
                                         & " write";
                                    end if;
                                    IR.Emit_Store_Indirect
                                      (Unit.all, Filling,
                                       IR.Emit_Load
                                         (Unit.all, Filling,
                                          Alias.Source.Address, Site),
                                       Value, Site);
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
                                    Nested => Element_Path,
                                    Variant_Case =>
                                      (if Element_Path'Length = 0
                                       then Alias.Which else 0),
                                    Variant_Payload_Field =>
                                      (if Element_Path'Length = 0
                                       then Alias.Payload_Field else 0));
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Element
                                   (Unit.all, Filling, Alias.Source.Slot,
                                    Index, Value, Site,
                                    Field => Alias.Field,
                                    Nested => Element_Path,
                                    Variant_Case =>
                                      (if Element_Path'Length = 0
                                       then Alias.Which else 0),
                                    Variant_Payload_Field =>
                                      (if Element_Path'Length = 0
                                       then Alias.Payload_Field else 0));
                              when IR.Runtime_Address =>
                                 declare
                                    Address : constant IR.Value_Id :=
                                      IR.Emit_Storage_Address
                                        (Unit.all, Filling, Alias.Source,
                                         Site, Field => Alias.Field,
                                         Nested => Payload_Steps
                                           (Alias_Steps (Of_Tree, Alias),
                                            Positive (Alias.Which),
                                            Positive
                                              (Alias.Payload_Field)),
                                         Index => Index);
                                 begin
                                    IR.Emit_Store_Indirect
                                      (Unit.all, Filling, Address, Value,
                                       Site);
                                 end;
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
                        At_Index : IR.Value_Id := Index;
                     begin
                        if At_Index = IR.No_Value
                          and then (Field > 0 or else Child_Steps'Length > 0)
                        then
                           pragma Assert (Is_Constant_Index (Of_Tree, Place));
                           At_Index := Lower_Expression
                             (Of_Tree, Syn.Index_Of (Of_Tree, Place), Scope);
                        end if;
                        if Res.Sort_Of (Meanings.all, Means)
                           /= Res.Module_Binding
                        then
                           if At_Index = IR.No_Value then
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling,
                                 Slot_For (Of_Tree, Named, Means),
                                 Constant_Index (Of_Tree, Place),
                                 Value, Site);
                           else
                              IR.Emit_Store_Slot_Element
                                (Unit.all, Filling,
                                 Slot_For (Of_Tree, Named, Means),
                                 At_Index, Value, Site, Field => Field,
                                 Nested => Child_Steps);
                           end if;
                        elsif At_Index = IR.No_Value then
                           IR.Emit_Store_Field
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means),
                              Constant_Index (Of_Tree, Place), Value, Site);
                        else
                           IR.Emit_Store_Element
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means),
                              At_Index, Value, Site, Field => Field,
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
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling, Into.Address,
                                 Leaf_Base (Base, Child_Steps),
                                 Value, Site,
                                 Nested => Leaf_Steps
                                   (Base, Child_Steps));
                        end case;
                     end;

                     return;
                  end if;

                  if Res.Sort_Of (Meanings.all, Means) = Res.Parameter then
                     declare
                        Their_Tree : constant not null access constant
                          Syn.Tree :=
                            Tree_For (Res.Source_Of (Meanings.all, Means));
                        Their_Node : constant Syn.Node_Id :=
                          Res.Node_Of (Meanings.all, Means);
                     begin
                        if Syn.Convention_Of (Their_Tree.all, Their_Node)
                             = Syn.Inout_Convention
                        then
                           IR.Emit_Store_Indirect
                             (Unit.all, Filling,
                              Slot_For (Of_Tree, Place, Means), Value, Site);
                           return;
                        end if;
                     end;
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
                     if Held in Ty.Slice_Value | Ty.Any_Value
                       and then Target = IR.No_Slot
                     then
                        Target := Add_Value_Temporary (Of_Tree, Stmt);
                     elsif Held in Ty.Aggregate | Ty.Fixed_Array
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
                       and then Syn.Kind (Of_Tree, Stmt)
                                  in Syn.Call | Syn.Labeled_Application
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
                       Ty.Scalar_Name | Ty.Function_Value | Ty.Pointer_Value
                          | Ty.Atom_Value
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
                             in Syn.Loop_Statement | Syn.While_Statement
                                | Syn.For_Statement
                     then
                        Lower_Loop
                          (Of_Tree, Stmt, Scope, Result, Target,
                           Destination_Field, Destination_Path);
                     elsif Syn.Kind (Of_Tree, Stmt)
                             in Syn.Call | Syn.Labeled_Application
                                | Syn.Try_Expression
                       and then not Is_Struct_Construction
                         (Of_Tree, Stmt)
                     then
                        Lower_Stored_Expression
                          (Of_Tree, Stmt, Scope, Target,
                           Destination_Field, Destination_Path);
                     elsif Held in Ty.Slice_Value | Ty.Any_Value then
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
                                in Ty.Slice_Value | Ty.Any_Value
                        then
                           Lower_Slice_Into
                             (Of_Tree, Value, Scope, Where);
                        elsif Landin.Checking.Type_Of (Types.all, Id)
                                = Ty.Fixed_Array
                        then
                           if Syn.Kind (Of_Tree, Value)
                                in Syn.If_Statement | Syn.Match_Statement
                                   | Syn.Bare_Block | Syn.Loop_Statement
                                   | Syn.While_Statement | Syn.For_Statement
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
                                 when Syn.Loop_Statement
                                    | Syn.While_Statement
                                    | Syn.For_Statement =>
                                    Lower_Loop
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when others =>
                                    raise Landin.Compiler_Defect;
                              end case;
                           elsif Syn.Kind (Of_Tree, Value)
                                   in Syn.Call | Syn.Labeled_Application
                                      | Syn.Try_Expression
                             and then not Is_Struct_Construction
                               (Of_Tree, Value)
                           then
                              Lower_Stored_Expression
                                (Of_Tree, Value, Scope, Where);
                           elsif Syn.Kind (Of_Tree, Value)
                                   in Syn.Array_Literal
                                      | Syn.Mixed_Array_Repetition
                                      | Syn.Array_Repetition
                             and then Neutral_Element
                               (Of_Tree, Value).Kind /= IR.Scalar_Field_Shape
                           then
                              --  A compound child is constructed in storage,
                              --  not lowered as a scalar expression or call.
                              Write_Array_Value
                                (Value, (Kind => IR.Frame_Slot, Slot => Where),
                                 Field => 0);
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
                              Write_Array_Value
                                (Value, (Kind => IR.Frame_Slot, Slot => Where),
                                 Field => 0);
                           end if;
                        elsif Landin.Checking.Type_Of (Types.all, Id)
                                = Ty.Aggregate
                        then
                           if Syn.Kind (Of_Tree, Value)
                                in Syn.If_Statement | Syn.Match_Statement
                                   | Syn.Bare_Block | Syn.Loop_Statement
                                   | Syn.While_Statement | Syn.For_Statement
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
                                 when Syn.Loop_Statement
                                    | Syn.While_Statement
                                    | Syn.For_Statement =>
                                    Lower_Loop
                                      (Of_Tree, Value, Scope, Result, Where);
                                 when others =>
                                    raise Landin.Compiler_Defect;
                              end case;
                           elsif Syn.Kind (Of_Tree, Value)
                                   in Syn.Call | Syn.Labeled_Application
                                      | Syn.Try_Expression
                             and then not Is_Struct_Construction
                               (Of_Tree, Value)
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
                          | Syn.Loop_Statement | Syn.While_Statement
                          | Syn.For_Statement
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
                                       IR.Note_Source_Alias
                                         (Unit.all, Filling,
                                          (Binding => Id,
                                           Site => Site_Of (Of_Tree, Stmt),
                                           Place => Source,
                                           Field => Aliases
                                             (Declared (Id)).Field,
                                           Initialized_On_Entry => False),
                                          IR.No_Path_Steps);
                                    end;
                                 end if;
                              end;
                           end loop;
                        end if;
                     end;

                  when Syn.Assignment =>
                     --  [0390]/[0410]: form the destination address and read
                     --  its old scalar value before the right-hand side.
                     --  Both are retained in frame slots because that value
                     --  may cross blocks.  The final indirect store therefore
                     --  cannot re-evaluate an index or pointer expression.
                     if Syn.Assignment_Operation (Of_Tree, Stmt)
                          /= Landin.Tokens.Plain_Assignment
                       and then Type_At
                         (Of_Tree, Syn.Target_Of (Of_Tree, Stmt))
                           = Ty.Fixed_Array
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Shape : constant IR.Field_Shape :=
                             Neutral_Value_Shape (Of_Tree, Place);
                           Reached : constant Stored_Place :=
                             Lower_Stored_Place (Of_Tree, Place, Scope);
                        begin
                           if Current /= IR.No_Block then
                              declare
                                 Destination : constant IR.Storage :=
                                   Addressed_Storage (Reached, Shape, Site);
                              begin
                                 Write_Array_Arithmetic
                                   (Of_Tree, Stmt, Scope, Shape,
                                    Stored_At (Destination));
                              end;
                           end if;
                        end;
                     elsif Syn.Assignment_Operation (Of_Tree, Stmt)
                          /= Landin.Tokens.Plain_Assignment
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Held : constant Ty.Scalar_Name :=
                             Scalar_At (Of_Tree, Place);
                           Dynamic : constant Boolean :=
                             Has_Computed_Index (Of_Tree, Place)
                             or else Has_Reference_Storage
                               (Of_Tree, Place);
                        begin
                           if Current /= IR.No_Block then
                              declare
                                 procedure Finish_Update
                                   (Was          : IR.Value_Id;
                                    Address_Slot : IR.Slot_Id := IR.No_Slot);

                                 procedure Finish_Update
                                   (Was          : IR.Value_Id;
                                    Address_Slot : IR.Slot_Id := IR.No_Slot)
                                 is
                                    Saved : constant IR.Slot_Id :=
                                      IR.Add_Slot
                                        (Unit.all, Filling, Held,
                                         Res.No_Declaration, Site);
                                 begin
                                    IR.Emit_Store
                                      (Unit.all, Filling, Saved, Was, Site);
                                    declare
                                       Right : constant IR.Value_Id :=
                                         Lower_Expression
                                           (Of_Tree,
                                            Syn.Value_Of (Of_Tree, Stmt),
                                            Scope);
                                    begin
                                       if Current /= IR.No_Block then
                                          declare
                                             Left : constant IR.Value_Id :=
                                               IR.Emit_Load
                                                 (Unit.all, Filling, Saved,
                                                  Site);
                                             Result : constant IR.Value_Id :=
                                               Checked_Update
                                                 (Of_Tree, Stmt,
                                                  IR.Emit_Binary
                                                    (Unit.all, Filling,
                                                     Update_Opcode
                                                       (Syn
                                                          .Assignment_Operation
                                                            (Of_Tree, Stmt)),
                                                     Left, Right, Held,
                                                     Site));
                                          begin
                                             if Address_Slot = IR.No_Slot then
                                                Write (Place, Result);
                                             else
                                                IR.Emit_Store_Indirect
                                                  (Unit.all, Filling,
                                                   Address_Slot, Result, Site);
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end Finish_Update;
                              begin
                                 if Dynamic then
                                    declare
                                       Reached : constant Stored_Place :=
                                         Lower_Stored_Place
                                           (Of_Tree, Place, Scope);
                                    begin
                                       if Current /= IR.No_Block then
                                          declare
                                             Address : constant IR.Storage :=
                                               Addressed_Storage
                                                 (Reached,
                                                  Neutral_Value_Shape
                                                    (Of_Tree, Place), Site);
                                             Was : constant IR.Value_Id :=
                                               IR.Emit_Load_Indirect
                                                 (Unit.all, Filling,
                                                  Address.Address, Site);
                                          begin
                                             Finish_Update
                                               (Was, Address.Address);
                                          end;
                                       end if;
                                    end;
                                 else
                                    Finish_Update
                                      (Read_Place (Place, IR.No_Value));
                                 end if;
                              end;
                           end if;
                        end;

                     --  D76's direct part assignment is contextual and its
                     --  target is Not_Typed rather than a general aggregate
                     --  value.  Lower it before the ordinary whole-struct
                     --  branch asks the place for an aggregate body.
                     elsif Syn.Kind
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

                     elsif Landin.Checking.Type_Of
                       (Types.all, Of_Tree,
                        Syn.Target_Of (Of_Tree, Stmt))
                          in Ty.Slice_Value | Ty.Any_Value
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           From : constant Syn.Node_Id :=
                             Syn.Value_Of (Of_Tree, Stmt);
                           Destination : constant Stored_Place :=
                             Lower_Stored_Place (Of_Tree, Place, Scope);
                        begin
                           if Destination.Place.Kind = IR.Frame_Slot
                             and then Destination.Base = 0
                             and then Destination.Steps.Is_Empty
                           then
                              Lower_Slice_Into
                                (Of_Tree, From, Scope,
                                 Destination.Place.Slot);
                           else
                              declare
                                 Temporary : constant IR.Slot_Id :=
                                   IR.Add_Array_Slot
                                     (Unit.all, Filling, Ty.Usize, 2,
                                      Res.No_Declaration, Site);
                              begin
                                 Lower_Slice_Into
                                   (Of_Tree, From, Scope, Temporary);
                                 IR.Emit_Array_Copy
                                   (Unit.all, Filling,
                                    (Kind => IR.Frame_Slot,
                                     Slot => Temporary),
                                    Destination.Place, Site,
                                    Destination_Field => Destination.Base,
                                    Destination_Nested =>
                                      Stored_Steps (Destination));
                              end;
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
                           Dynamic : constant Boolean :=
                             Has_Computed_Index (Of_Tree, Place)
                             or else Has_Reference_Storage
                               (Of_Tree, Place);
                           Named : constant Syn.Node_Id :=
                             (if Dynamic then Syn.No_Node
                              else Chain_Root (Of_Tree, Place));
                           Parent_Field : constant Natural :=
                             (if Dynamic then 0
                              else Rooted_Base (Of_Tree, Place));
                           Parent_Steps : constant IR.Path_Step_Array :=
                             (if Dynamic then IR.No_Path_Steps
                              else Rooted_Steps (Of_Tree, Place));
                           Destination : constant IR.Storage :=
                             (if Dynamic
                              then (Kind => IR.Frame_Slot,
                                    Slot => IR.No_Slot)
                              else Storage_For (Of_Tree, Named));
                        begin
                           if Dynamic then
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
                                                      Lower_Stored_Expression
                                                        (Of_Tree, From, Scope,
                                                         Temporary);
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
                                   | Syn.Bare_Block | Syn.Loop_Statement
                                   | Syn.While_Statement | Syn.For_Statement
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
                                    when Syn.Loop_Statement
                                       | Syn.While_Statement
                                       | Syn.For_Statement =>
                                       Lower_Loop
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
                                   in Syn.Call | Syn.Labeled_Application
                                      | Syn.Try_Expression
                             and then not Is_Struct_Construction
                               (Of_Tree, From)
                           then
                              if Destination.Kind = IR.Frame_Slot then
                                 if Syn.Kind (Of_Tree, From)
                                      /= Syn.Try_Expression
                                 then
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
                              else
                                 --  The internal call convention writes a
                                 --  stored aggregate into a caller-owned
                                 --  frame slot.  An inout aggregate may be
                                 --  indirect, so receive the result in an
                                 --  ordinary temporary before copying its
                                 --  fields to the selected destination.
                                 declare
                                    Wrote : constant
                                      Landin.Checking.Nominal_Type_Id :=
                                      Landin.Checking.Nominal_Of
                                        (Types.all, Of_Tree, Place);
                                    Shape : constant IR.Field_Shape :=
                                      Neutral_Body (Wrote);
                                    Temporary : constant IR.Slot_Id :=
                                      Add_Value_Temporary (Of_Tree, From);
                                    Temp_Place : constant Stored_Place :=
                                      (Place =>
                                         (Kind => IR.Frame_Slot,
                                          Slot => Temporary),
                                       Base => 0,
                                       Steps => Stored_Path_Vectors
                                         .Empty_Vector);
                                    Into_Place : Stored_Place :=
                                      (Place => Destination,
                                       Base => Parent_Field,
                                       Steps => Stored_Path_Vectors
                                         .Empty_Vector);
                                 begin
                                    for Step of Parent_Steps loop
                                       Into_Place.Steps.Append (Step);
                                    end loop;
                                    Lower_Stored_Expression
                                      (Of_Tree, From, Scope, Temporary);
                                    if Current /= IR.No_Block then
                                       declare
                                          Source : constant IR.Storage :=
                                            Addressed_Storage
                                              (Temp_Place, Shape, Site);
                                          Into : constant IR.Storage :=
                                            Addressed_Storage
                                              (Into_Place, Shape, Site);
                                       begin
                                          IR.Emit_Array_Copy
                                            (Unit.all, Filling, Source, Into,
                                             Site);
                                       end;
                                    end if;
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
                           Dynamic : constant Boolean :=
                             Has_Computed_Index (Of_Tree, Place)
                             or else Has_Reference_Storage
                               (Of_Tree, Place);
                        begin
                           if Dynamic then
                              declare
                                 Reached : constant Stored_Place :=
                                   Lower_Stored_Place
                                     (Of_Tree, Place, Scope);
                              begin
                                 if Current /= IR.No_Block then
                                    declare
                                       Shape : constant IR.Field_Shape :=
                                         Neutral_Value_Shape (Of_Tree, Place);
                                       Into : constant IR.Storage :=
                                         Addressed_Storage
                                           (Reached, Shape, Site);
                                    begin
                                       if Syn.Kind (Of_Tree, Value)
                                            in Syn.Call | Syn.Try_Expression
                                               | Syn.If_Statement
                                               | Syn.Match_Statement
                                               | Syn.Bare_Block
                                               | Syn.Loop_Statement
                                               | Syn.While_Statement
                                               | Syn.For_Statement
                                       then
                                          declare
                                             Temporary : constant IR.Slot_Id :=
                                               Add_Value_Temporary
                                                 (Of_Tree, Value);
                                          begin
                                             Lower_Stored_Expression
                                               (Of_Tree, Value, Scope,
                                                Temporary);
                                             if Current /= IR.No_Block then
                                                IR.Emit_Array_Copy
                                                  (Unit.all, Filling,
                                                   Source =>
                                                     (Kind => IR.Frame_Slot,
                                                      Slot => Temporary),
                                                   Destination => Into,
                                                   Site => Site);
                                             end if;
                                          end;
                                       else
                                          Write_Array_Value
                                            (Value, Into, Field => 0);
                                       end if;
                                    end;
                                 end if;
                              end;
                           else
                              declare
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
                                      in Syn.If_Statement
                                         | Syn.Match_Statement
                                         | Syn.Bare_Block
                                         | Syn.Loop_Statement
                                         | Syn.While_Statement
                                         | Syn.For_Statement
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
                                             Destination_Nested =>
                                               Child_Steps);
                                       end if;
                                    end;
                                 elsif Syn.Kind (Of_Tree, Value)
                                         in Syn.Call | Syn.Try_Expression
                                 then
                                    pragma Assert
                                      (Destination.Kind in IR.Frame_Slot);
                                    declare
                                       Actual_Call : constant Syn.Node_Id :=
                                         (if Syn.Kind (Of_Tree, Value)
                                               = Syn.Call
                                          then Value
                                          else Syn.Operand_Of
                                            (Of_Tree, Value));
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
                           end if;
                        end;
                     else
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Address_Slot : constant IR.Slot_Id :=
                             Reference_Address_For (Place);
                           Index : constant IR.Value_Id :=
                             (if Current = IR.No_Block
                                 or else Address_Slot /= IR.No_Slot
                              then IR.No_Value else Index_For (Place));
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
                                       Write
                                         (Place, Value, Carried_Index,
                                          Address_Slot);
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
                        Address_Slot : constant IR.Slot_Id :=
                          Reference_Address_For (Place);
                        Index : constant IR.Value_Id :=
                          (if Current = IR.No_Block
                              or else Address_Slot /= IR.No_Slot
                           then IR.No_Value else Index_For (Place));
                        Op : constant IR.Opcode :=
                          (if Syn.Kind (Of_Tree, Stmt) = Syn.Increment
                           then IR.Add else IR.Subtract);
                     begin
                        if Current /= IR.No_Block then
                           declare
                              Was : constant IR.Value_Id :=
                                Read_Place (Place, Index, Address_Slot);
                           begin
                              if Current /= IR.No_Block then
                                 declare
                                    One : constant IR.Value_Id :=
                                      IR.Emit_Number
                                        (Unit.all, Filling, Held, 1, False,
                                         Site);
                                    Updated : constant IR.Value_Id :=
                                      Checked_Update
                                        (Of_Tree, Stmt,
                                         IR.Emit_Binary
                                           (Unit.all, Filling, Op, Was, One,
                                            Held, Site));
                                 begin
                                    Write
                                      (Place, Updated, Index, Address_Slot);
                                 end;
                              end if;
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
                                | Ty.Slice_Value | Ty.Any_Value
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

                  when Syn.Call | Syn.Labeled_Application =>
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
                           Active => True,
                           Region =>
                             IR.Unchecked_Depth (Unit.all, Filling)));

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

                  when Syn.Break_Statement | Syn.Continue_Statement =>
                     Lower_Loop_Transfer (Of_Tree, Stmt, Scope);

                  when Syn.Loop_Statement | Syn.While_Statement
                     | Syn.For_Statement =>
                     Lower_Loop (Of_Tree, Stmt, Scope, Result);

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

      procedure Lower_Routine
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id;
         Bound_Item : IR.Item_Id := IR.No_Item;
         Bound_Target : IR.Item_Id := IR.No_Item);

      procedure Lower_Routine
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id;
         Bound_Item : IR.Item_Id := IR.No_Item;
         Bound_Target : IR.Item_Id := IR.No_Item)
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
           (if Bound_Item /= IR.No_Item then Bound_Item
            elsif Landin.Checking.Current_Routine_View (Types.all)
                  /= Landin.Checking.No_Routine_Instance
            then IR.Item_For_Instance
              (Unit.all,
               Landin.Checking.Routine_Identities.Position
                 (Types.all,
                  Landin.Checking.Current_Routine_View (Types.all)))
            elsif Owner = Res.No_Declaration
            then Anonymous_Item (Of_Tree, Node)
            else IR.Item_For (Unit.all, Owner));
         if Syn.Kind (Of_Tree, Node) = Syn.Function_Declaration
           and then Syn.Is_Public (Of_Tree, Node)
         then
            IR.Mark_Address_Exposed (Unit.all, Filling);
         end if;
         Slots := No_Slots;
         Evidence_Slots := [others => IR.No_Slot];
         pragma Assert (Cleanup_Stack.Is_Empty);
         Cleanup_Stack.Clear;

         --  D106's first internal parameter is an unspellable pointer to
         --  caller-owned result storage.  Source parameters follow it through
         --  the same register/stack run.
         if Gives_Type in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
              | Ty.Any_Value
         then
            declare
               Ignored : constant IR.Slot_Id :=
                 IR.Add_Parameter
                   (Unit.all, Filling, Ty.Usize, Owner, Site);
            begin
               pragma Unreferenced (Ignored);
            end;
         end if;

         --  R2.70 evidence pointers are hidden runtime parameters after the
         --  aggregate destination and before every written parameter.  Their
         --  order is constrained generic-formal declaration order.
         declare
            View : constant Landin.Checking.Routine_Instance_Id :=
              Landin.Checking.Current_Routine_View (Types.all);
         begin
            if View /= Landin.Checking.No_Routine_Instance
              and then Bound_Item = IR.No_Item
            then
               for Which in 1 .. Landin.Checking.Routine_Evidence_Count
                 (Types.all, View)
               loop
                  declare
                     Source : constant Landin.Checking.Conformance_Id :=
                       Landin.Checking.Nth_Routine_Evidence
                         (Types.all, View, Which);
                     Position : constant Positive :=
                       Landin.Checking.Conformance_Identities.Position
                         (Types.all, Source);
                  begin
                     Evidence_Slots (Position) := IR.Add_Parameter
                       (Unit.all, Filling, Ty.Usize, Res.No_Declaration, Site);
                     IR.Bind_Evidence_Parameter
                       (Unit.all, Filling,
                        IR.Parameter_Count (Unit.all, Filling),
                        Evidence_For (Source));
                  end;
               end loop;
            end if;
         end;

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
               if Syn.Convention_Of (Of_Tree, Param) = Syn.Inout_Convention
               then
                  declare
                     Shape : IR.Field_Shape;
                  begin
                     if Held = Ty.Aggregate then
                        Shape := Neutral_Body
                          (Landin.Checking.Nominal_Of (Types.all, Id));
                     elsif Held = Ty.Fixed_Array then
                        declare
                           Element : constant IR.Field_Shape :=
                             Neutral_Element (Id);
                        begin
                           Shape := IR.Make_Array_Shape
                             (Unit.all, IR.Element_Total
                                (Landin.Checking.Array_Length (Types.all, Id)),
                              Element);
                        end;
                     elsif Held in Ty.Slice_Value | Ty.Any_Value then
                        Shape :=
                          (Kind => IR.Array_Field_Shape,
                           Element => Ty.Usize, Length => 2, others => <>);
                     else
                        Shape :=
                          (Kind => IR.Scalar_Field_Shape,
                           Element =>
                             (if Held in Ty.Function_Value | Ty.Pointer_Value
                              then Ty.Usize
                              elsif Held = Ty.Atom_Value then Ty.U32
                              else Ty.Scalar_Name (Held)),
                           Length => 1,
                           Pointee =>
                             (if Held = Ty.Pointer_Value
                              then Pointee_For
                                (Landin.Checking.Reference_Of (Types.all, Id))
                              else IR.No_Pointee),
                           Signature =>
                             (if Held = Ty.Function_Value
                              then Signature_For
                                (Landin.Checking.Signature_Of (Types.all, Id))
                              else IR.No_Signature),
                           Atoms =>
                             (if Held = Ty.Atom_Value
                              then Atom_Set_For
                                (Landin.Checking.Atom_Set_Of (Types.all, Id))
                              else IR.No_Atom_Set),
                           others => <>);
                     end if;
                     Slots (Positive (Id)) :=
                       IR.Add_Address_Parameter
                         (Unit.all, Filling, Shape, Id,
                          Site_Of (Of_Tree, Param));
                     pragma Assert
                       (IR.Is_Address
                          (Unit.all, Filling, Slots (Positive (Id))));
                  end;
               elsif Held in Ty.Slice_Value | Ty.Any_Value then
                  Slots (Positive (Id)) :=
                    IR.Add_Array_Parameter
                      (Unit.all, Filling, Ty.Usize, 2, Id,
                       Site_Of (Of_Tree, Param));
               elsif Held = Ty.Aggregate then
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
                 Ty.Scalar_Name | Ty.Function_Value | Ty.Pointer_Value
                    | Ty.Atom_Value
               then
                  Slots (Positive (Id)) :=
                    IR.Add_Parameter
                      (Unit.all, Filling,
                       (if Held in Ty.Function_Value | Ty.Pointer_Value
                        then Ty.Usize
                        elsif Held = Ty.Atom_Value then Ty.U32
                        else Held),
                       Id, Site_Of (Of_Tree, Param),
                       Pointee =>
                         (if Held = Ty.Pointer_Value
                          then Pointee_For
                            (Landin.Checking.Reference_Of (Types.all, Id))
                          else IR.No_Pointee),
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
                  IR.Note_Source_Alias
                    (Unit.all, Filling,
                     (Binding => Id, Site => Site_Of (Of_Tree, Returned),
                      Place => (Kind => IR.Frame_Slot, Slot => Result),
                      Field => Which, Initialized_On_Entry => False),
                     IR.No_Path_Steps);
               end;
            end loop;
         end if;

         Active_Result := Result;

         if Bound_Target /= IR.No_Item then
            --  Forward the complete source ABI, inserting only this concrete
            --  provider's evidence environment. The ordinary generic body
            --  remains the implementation, including its failure channel.
            declare
               View : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Current_Routine_View (Types.all);
               Hidden : constant Natural :=
                 Landin.Checking.Routine_Evidence_Count (Types.all, View);
               Stored : constant Boolean := Gives_Type in
                 Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value | Ty.Any_Value;
               Count : constant Natural := IR.Parameter_Count
                 (Unit.all, Filling);
               type Argument_Array is array (Positive range <>)
                 of IR.Value_Id;
               Arguments : Argument_Array (1 .. Count + Hidden);
               Argument_Count : Natural := 0;
               Errors : constant IR.Atom_Set_Id := IR.Signature_Errors
                 (Unit.all, IR.Signature_Of (Unit.all, Bound_Target));
               Failure : IR.Slot_Id := IR.No_Slot;
               Call : IR.Value_Id;
            begin
               Open (Fresh (Of_Tree, Runs, Signature));
               if Stored then
                  Argument_Count := Argument_Count + 1;
                  Arguments (Argument_Count) := IR.Emit_Storage_Address
                    (Unit.all, Filling,
                     (Kind => IR.Frame_Slot, Slot => Result), Site);
               end if;
               for Which in 1 .. Hidden loop
                  Argument_Count := Argument_Count + 1;
                  Arguments (Argument_Count) := IR.Emit_Evidence_Address
                    (Unit.all, Filling, Evidence_For
                       (Landin.Checking.Nth_Routine_Evidence
                          (Types.all, View, Which)), Site);
               end loop;
               for Which in (if Stored then 2 else 1) .. Count loop
                  declare
                     Slot : constant IR.Slot_Id := IR.Nth_Parameter
                       (Unit.all, Filling, Which);
                  begin
                     Argument_Count := Argument_Count + 1;
                     if IR.Is_Address (Unit.all, Filling, Slot) then
                        Arguments (Argument_Count) := IR.Emit_Place_Address
                          (Unit.all, Filling,
                           (Kind => IR.Runtime_Address, Address => Slot),
                           Site);
                     elsif IR.Is_Aggregate (Unit.all, Filling, Slot)
                       or else IR.Is_Array (Unit.all, Filling, Slot)
                     then
                        Arguments (Argument_Count) := IR.Emit_Storage_Address
                          (Unit.all, Filling,
                           (Kind => IR.Frame_Slot, Slot => Slot), Site);
                     else
                        Arguments (Argument_Count) := IR.Emit_Load
                          (Unit.all, Filling, Slot, Site);
                     end if;
                  end;
               end loop;
               if Errors /= IR.No_Atom_Set then
                  Failure := IR.Add_Slot
                    (Unit.all, Filling, Ty.U32, Res.No_Declaration, Site,
                     Atoms => Errors);
               end if;
               Call := IR.Emit_Call
                 (Unit.all, Filling, Bound_Target,
                  (if Stored then Ty.No_Value
                   else IR.Result_Of (Unit.all, Bound_Target)), Site,
                  Failure => Failure);
               for Argument of Arguments loop
                  IR.Add_Argument (Unit.all, Filling, Call, Argument);
               end loop;
               if not Stored and then Result /= IR.No_Slot then
                  IR.Emit_Store (Unit.all, Filling, Result, Call, Site);
               end if;
               if Failure /= IR.No_Slot then
                  declare
                     Error : constant IR.Value_Id := IR.Emit_Load
                       (Unit.all, Filling, Failure, Site);
                     Test : constant IR.Value_Id := IR.Emit_Failure_Test
                       (Unit.all, Filling, Error, Site);
                     Failed : constant IR.Block_Id := Fresh
                       (Of_Tree, Runs, Signature);
                     Succeeded : constant IR.Block_Id := Fresh
                       (Of_Tree, Runs, Signature);
                  begin
                     IR.Emit_Branch
                       (Unit.all, Filling, Test, Failed, Succeeded, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;
                     Open (Failed);
                     declare
                        Carried : constant IR.Value_Id := IR.Emit_Load
                          (Unit.all, Filling, Failure, Site);
                     begin
                        IR.Emit_Fail (Unit.all, Filling, Carried, Site);
                     end;
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;
                     Open (Succeeded);
                  end;
               end if;
               Leave_With (Result, Site);
            end;
         elsif Syn.Kind (Of_Tree, Runs) = Syn.Block then
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

            if Gives_Type
              in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
                 | Ty.Any_Value
            then
               Lower_Stored_Expression
                 (Of_Tree, Runs, Signature, Result);
            else
               declare
                  Value : constant IR.Value_Id :=
                    Lower_Expression (Of_Tree, Runs, Signature);
               begin
                  if Current /= IR.No_Block and then Result /= IR.No_Slot then
                     IR.Emit_Store
                       (Unit.all, Filling, Result, Value, Site);
                  end if;
               end;
            end if;

            --  D124: an expression body can leave while evaluating an
            --  operand.  That exit already read the definitely assigned
            --  named result; only a surviving path fills and leaves it here.
            if Current /= IR.No_Block then
               Leave_With (Result, Site);
            end if;
         end if;

         Filling := IR.No_Item;
         Active_Result := IR.No_Slot;
         pragma Assert (Cleanup_Stack.Is_Empty);
      end Lower_Routine;

      ------------------------------------------------------------
      --  [1940]: a module value
      ------------------------------------------------------------

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
         if Held not in Ty.Scalar_Name | Ty.Function_Value | Ty.Pointer_Value
              | Ty.Atom_Value
           and then Held not in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
              | Ty.Any_Value
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
         if Held in Ty.Aggregate | Ty.Fixed_Array | Ty.Slice_Value
              | Ty.Any_Value
         then
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

         if Held = Ty.Bool then
            --  D177: a module bool is resolved by the same static folder as
            --  an aggregate bool leaf in pass three.  Logical words are CFG
            --  inside a routine, but a datum is an image and nothing executes
            --  before the entry point [1460].
            IR.Emit_Leave (Unit.all, Filling, IR.No_Value, Site);
            IR.Leave_Block (Unit.all, Filling);
            Current := IR.No_Block;
            Filling := IR.No_Item;
            return;
         end if;

         if Has_Distinct_Image (Id) then
            if Held = Ty.Atom_Value then
               Answer := IR.Emit_Atom
                 (Unit.all, Filling, Res.Declaration_Id (Distinct_Image (Id)),
                  Atom_Set_For (Landin.Checking.Atom_Set_Of (Types.all, Id)),
                  Site);
            elsif Held in Ty.Float_Name then
               Answer := IR.Emit_Float
                 (Unit.all, Filling, Held,
                  Ty.Magnitude (Distinct_Image (Id)), Site);
            else
               Answer := IR.Emit_Number
                 (Unit.all, Filling, Held,
                  Ty.Magnitude (abs Distinct_Image (Id)),
                  Distinct_Image (Id) < 0, Site);
            end if;
         elsif Held = Ty.Function_Value then
            --  Static dependencies are already resolved, including leaves
            --  of later images.  Emit the datum in declaration order.
            Answer := IR.Emit_Function_Address
              (Unit.all, Filling, IR.Function_Target (Unit.all, Filling),
               Site);
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

      --  A C classifier needs the nominal body even when a type occurs
      --  only in an imported signature or behind a callback.  Storage is
      --  not an authority for that body: register all completed checker
      --  layouts after identities exist and before any call is emitted.
      for Position in 1 .. Landin.Checking.Nominal_Type_Count (Types.all) loop
         declare
            Source : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nth_Nominal_Type (Types.all, Position);
         begin
            if Landin.Checking.Has_Layout (Types.all, Source) then
               declare
                  Fields : IR.Field_Shape_Array
                    (1 .. Landin.Checking.Layout_Field_Count
                      (Types.all, Source));
               begin
                  for Field in Fields'Range loop
                     Fields (Field) := Neutral_Field (Source, Field);
                  end loop;
                  IR.Set_Nominal_Shape
                    (Unit.all, Nominals (Position), Fields,
                     Policy => Landin.Checking.Layout_Of
                       (Types.all, Source));
               end;
            end if;
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
            Id : constant Res.Declaration_Id :=
              (if Syn.Kind (Of_Tree, Node)
                    in Syn.Concept_Declaration
                       | Syn.Conformance_Declaration
               then Res.No_Declaration else Declaration_At (Src, Node));
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
                  Source_Signature : constant
                    Landin.Checking.Signature_Id :=
                      Landin.Checking.Signature_Of (Types.all, Id);
                  Result_Part : constant Landin.Checking.Signature_Part :=
                    (if Count = 1
                       and then Syn.Generic_Formal_Count (Of_Tree, Node) = 0
                     then Landin.Checking.Nth_Signature_Result
                       (Types.all, Source_Signature, 1)
                     else (Kind => Ty.No_Value, others => <>));
               begin
                  if Syn.Generic_Formal_Count (Of_Tree, Node) /= 0 then
                     --  D138 templates are compile-time syntax only; a
                     --  concrete instance owns the local routine item.
                     Made := IR.No_Item;
                  else
                     Made :=
                       IR.Add_Item
                         (Unit.all, IR.Routine, Id,
                          (if Held in Ty.Function_Value | Ty.Pointer_Value
                           then Ty.Usize
                           elsif Held = Ty.Atom_Value then Ty.U32
                           elsif Held in Ty.Slice_Value | Ty.Any_Value
                           then Ty.Fixed_Array
                           else Held),
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
                     elsif Held = Ty.Fixed_Array then
                        IR.Set_Array
                          (Unit.all, Made, Neutral_Element (Result_Part),
                           IR.Element_Total (Result_Part.Length));
                     elsif Held in Ty.Slice_Value | Ty.Any_Value then
                        IR.Set_Array
                          (Unit.all, Made, Ty.Usize, 2);
                     end if;
                     IR.Set_Signature
                       (Unit.all, Made, Signature_For (Source_Signature));
                     if Syn.Is_Public (Of_Tree, Node) then
                        IR.Mark_Address_Exposed (Unit.all, Made);
                     end if;
                     if Syn.Is_External (Of_Tree, Node) then
                        IR.Mark_External (Unit.all, Made);
                     end if;
                     if Landin.Checking.Link_Symbol (Types.all, Id)
                          /= Landin.Source.Names.No_Name
                     then
                        IR.Set_Link_Symbol
                          (Unit.all, Made,
                           Landin.Checking.Link_Symbol (Types.all, Id));
                     end if;
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
                       (if Held in Ty.Function_Value | Ty.Pointer_Value
                        then Ty.Usize
                        elsif Held = Ty.Atom_Value
                        then Ty.U32
                        elsif Held in Ty.Slice_Value | Ty.Any_Value
                           then Ty.Fixed_Array
                        else Held),
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

                  if Held = Ty.Pointer_Value then
                     IR.Set_Pointee
                       (Unit.all, Made, Pointee_For
                         (Landin.Checking.Reference_Of (Types.all, Id)));
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
                  if Held in Ty.Slice_Value | Ty.Any_Value then
                     IR.Set_Array (Unit.all, Made, Ty.Usize, 2);
                  elsif Held = Ty.Fixed_Array then
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
                       (if Held in Ty.Function_Value | Ty.Pointer_Value
                        then Ty.Usize
                        elsif Held = Ty.Atom_Value then Ty.U32
                        elsif Held in Ty.Slice_Value | Ty.Any_Value
                           then Ty.Fixed_Array
                        else Held),
                       Site_Of (Of_Tree.all, Node),
                       Nominal =>
                         (if Held = Ty.Aggregate and then Result_Count = 1
                          then Nominal_For (Part.Nominal)
                          else IR.No_Nominal_Type));
               begin
                  if Held = Ty.Atom_Value then
                     IR.Set_Atom_Set
                       (Unit.all, Made, Atom_Set_For (Part.Atoms));
                  elsif Held in Ty.Slice_Value | Ty.Any_Value then
                     IR.Set_Array (Unit.all, Made, Ty.Usize, 2);
                  elsif Held = Ty.Fixed_Array then
                     --  A generic item has no declaration-local array fact;
                     --  its complete substituted result lives in the
                     --  instance signature.  Preserve the nominal element
                     --  even at length zero, just as parameter/result slots
                     --  and the ABI signature do.
                     IR.Set_Array
                       (Unit.all, Made, Neutral_Element (Part),
                        IR.Element_Total (Part.Length));
                  end if;
                  IR.Set_Signature
                    (Unit.all, Made, Signature_For_Instance (Source));
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
                           elsif Held = Ty.Atom_Value then Ty.U32
                           elsif Held in Ty.Slice_Value | Ty.Any_Value
                           then Ty.Fixed_Array
                           else Held),
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
                     elsif Held in Ty.Slice_Value | Ty.Any_Value then
                        IR.Set_Array (Unit.all, Made, Ty.Usize, 2);
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

      --  D144's direct generic table and D145's flattened runtime table
      --  are separate physical objects over the same conformance evidence.
      --  The latter keeps `any C` two words while parent conformances remain
      --  separate semantic identities.
      declare
         type Boolean_Array is array (Positive range <>) of Boolean;

         function Concept_For
           (Of_Tree : Syn.Tree; Reference : Syn.Node_Id)
            return Landin.Checking.Concept_Id;

         function Concept_For
           (Of_Tree : Syn.Tree; Reference : Syn.Node_Id)
            return Landin.Checking.Concept_Id
         is
         begin
            if Res.Verdict_Of (Meanings.all, Of_Tree, Reference) /= Res.Bound
            then
               return Landin.Checking.No_Concept;
            end if;
            declare
               Declaration : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Reference);
            begin
               for Position in 1 .. Landin.Checking.Concept_Count
                 (Types.all)
               loop
                  declare
                     Candidate : constant Landin.Checking.Concept_Id :=
                       Landin.Checking.Concept_Identities.Nth
                         (Types.all, Position);
                  begin
                     if not Landin.Checking.Is_Compiler_Concept
                       (Types.all, Candidate)
                       and then Landin.Checking.Concept_Declaration
                         (Types.all, Candidate) = Declaration
                     then
                        return Candidate;
                     end if;
                  end;
               end loop;
               return Landin.Checking.No_Concept;
            end;
         end Concept_For;

         Used_Any_Evidence : Boolean_Array
           (1 .. Landin.Checking.Conformance_Count (Types.all)) :=
             [others => False];

         procedure Collect_Any_Evidence (Of_Tree : Syn.Tree);

         procedure Collect_Any_Evidence (Of_Tree : Syn.Tree) is
         begin
            for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Of_Tree) loop
               --  Naming or copying an any type does not require an
               --  object-safe table. Only checked constructions and entry
               --  selections carry the exact evidence erased lowering uses.
               --  A selection's shape witness need not itself be constructed.
               if Syn.Kind (Of_Tree, Node) = Syn.Any_Construction
                 or else
                   (Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
                    and then Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                      /= Res.Bound
                    and then Landin.Checking.Type_Of
                      (Types.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
                        = Ty.Any_Value)
               then
                  declare
                     Source : constant Landin.Checking.Conformance_Id :=
                       Landin.Checking.Evidence_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     if Source /= Landin.Checking.No_Conformance then
                        Used_Any_Evidence
                          (Landin.Checking.Conformance_Identities.Position
                             (Types.all, Source)) := True;
                     end if;
                  end;
               end if;
            end loop;
         end Collect_Any_Evidence;

         procedure Add_Provider
           (To_Evidence : IR.Evidence_Id;
            Row         : Landin.Checking.Conformance_Id;
            Position    : Positive);

         procedure Add_Provider
           (To_Evidence : IR.Evidence_Id;
            Row         : Landin.Checking.Conformance_Id;
            Position    : Positive)
         is
            Provider_Instance : constant
              Landin.Checking.Routine_Instance_Id :=
                Landin.Checking.Conformance_Provider_Instance
                  (Types.all, Row, Position);
            Provider : constant Res.Declaration_Id :=
              Landin.Checking.Conformance_Provider_Declaration
                (Types.all, Row, Position);
            Target : constant IR.Item_Id :=
              (if Provider_Instance /= Landin.Checking.No_Routine_Instance
               then IR.Item_For_Instance
                 (Unit.all,
                  Landin.Checking.Routine_Identities.Position
                    (Types.all, Provider_Instance))
               elsif Provider /= Res.No_Declaration
               then IR.Item_For (Unit.all, Provider)
               else IR.No_Item);
            Signature : constant Landin.Checking.Signature_Id :=
              (if Provider_Instance /= Landin.Checking.No_Routine_Instance
               then Landin.Checking.Routine_Signature_Of
                 (Types.all, Provider_Instance)
               elsif Provider /= Res.No_Declaration
               then Landin.Checking.Signature_Of (Types.all, Provider)
               else Landin.Checking.No_Signature);
         begin
            if Target = IR.No_Item
              or else Signature = Landin.Checking.No_Signature
            then
               raise Landin.Compiler_Defect with
                 "a selected evidence provider has no routine item";
            end if;
            if Provider_Instance /= Landin.Checking.No_Routine_Instance
              and then Landin.Checking.Routine_Evidence_Count
                (Types.all, Provider_Instance) > 0
            then
               declare
                  Index : constant Positive :=
                    Landin.Checking.Routine_Identities.Position
                      (Types.all, Provider_Instance);
               begin
                  if Provider_Items (Index) = IR.No_Item then
                     declare
                        Made : constant IR.Item_Id := IR.Add_Item
                          (Unit.all, IR.Routine, Res.No_Declaration,
                           IR.Result_Of (Unit.all, Target),
                           IR.Origin_Of (Unit.all, Target),
                           IR.Nominal_Of (Unit.all, Target));
                     begin
                        if IR.Atom_Set_Of (Unit.all, Target) /= IR.No_Atom_Set
                        then
                           IR.Set_Atom_Set
                             (Unit.all, Made,
                              IR.Atom_Set_Of (Unit.all, Target));
                        elsif IR.Result_Of (Unit.all, Target) = Ty.Fixed_Array
                        then
                           IR.Set_Array
                             (Unit.all, Made,
                              IR.Array_Element_Shape (Unit.all, Target),
                              IR.Array_Length (Unit.all, Target));
                        end if;
                        IR.Set_Signature
                          (Unit.all, Made, Signature_For (Signature));
                        Provider_Items (Index) := Made;
                        Bound_Provider_Count := Bound_Provider_Count + 1;
                        Bound_Providers (Bound_Provider_Count) :=
                          (Source => Provider_Instance,
                           Item => Made, Target => Target);
                     end;
                  end if;
                  IR.Add_Evidence_Entry
                    (Unit.all, To_Evidence, Provider_Items (Index),
                     Signature_For (Signature));
               end;
            else
               IR.Add_Evidence_Entry
                 (Unit.all, To_Evidence, Target, Signature_For (Signature));
            end if;
         end Add_Provider;

         procedure Add_Closure
           (To_Evidence : IR.Evidence_Id;
            Row         : Landin.Checking.Conformance_Id;
            Seen        : in out Boolean_Array);

         procedure Add_Closure
           (To_Evidence : IR.Evidence_Id;
            Row         : Landin.Checking.Conformance_Id;
            Seen        : in out Boolean_Array)
         is
            Concept : constant Landin.Checking.Concept_Id :=
              Landin.Checking.Conformance_Concept (Types.all, Row);
            Concept_Position : constant Positive :=
              Landin.Checking.Concept_Identities.Position
                (Types.all, Concept);
         begin
            if Seen (Concept_Position) then
               return;
            end if;
            Seen (Concept_Position) := True;
            for Position in 1 .. Landin.Checking.Conformance_Entry_Count
              (Types.all, Row)
            loop
               Add_Provider (To_Evidence, Row, Position);
            end loop;
            if Landin.Checking.Is_Compiler_Concept (Types.all, Concept) then
               return;
            end if;
            declare
               Declaration : constant Res.Declaration_Id :=
                 Landin.Checking.Concept_Declaration (Types.all, Concept);
               Concept_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Res.Source_Of (Meanings.all, Declaration));
               Concept_Node : constant Syn.Node_Id :=
                 Res.Node_Of (Meanings.all, Declaration);

               procedure Add_Parent (Reference : Syn.Node_Id);

               procedure Add_Parent (Reference : Syn.Node_Id) is
                  Parent : constant Landin.Checking.Concept_Id :=
                    Concept_For (Concept_Tree.all, Reference);
                  Parent_Row : Landin.Checking.Conformance_Id :=
                    Landin.Checking.No_Conformance;
               begin
                  if Parent = Landin.Checking.No_Concept then
                     return;
                  end if;
                  Parent_Row := Landin.Checking.Find_Conformance
                    (Types.all, Parent,
                     Landin.Checking.Conformance_Target (Types.all, Row),
                     Landin.Checking.Empty_Actuals);
                  if Parent_Row = Landin.Checking.No_Conformance then
                     raise Landin.Compiler_Defect with
                       "an any conformance closure has no parent table";
                  end if;
                  Add_Closure (To_Evidence, Parent_Row, Seen);
               end Add_Parent;
            begin
               declare
                  Represented : constant Syn.Node_Id :=
                    Syn.Nth_Concept_Formal
                      (Concept_Tree.all, Concept_Node, 1);
                  Required : constant Syn.Node_Id :=
                    Syn.Constraint_Of (Concept_Tree.all, Represented);
               begin
                  if Required /= Syn.No_Node then
                     Add_Parent (Required);
                  end if;
               end;
               for Parent in 1 .. Syn.Concept_Parent_Count
                 (Concept_Tree.all, Concept_Node)
               loop
                  Add_Parent
                    (Syn.Nth_Concept_Parent
                       (Concept_Tree.all, Concept_Node, Parent));
               end loop;
            end;
         end Add_Closure;
      begin
         --  Generic erased uses carry their evidence in the concrete
         --  checker view. Inventory those views before mapping erased tables.
         for Index in 1 .. Source_Count (Context) loop
            Collect_Any_Evidence (Tree_For (Nth_Source (Context, Index)).all);
         end loop;

         for Position in
           1 .. Landin.Checking.Routine_Instance_Count (Types.all)
         loop
            declare
               Instance : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Routine_Identities.Nth
                   (Types.all, Position);
            begin
               if Landin.Checking.Routine_State_Of (Types.all, Instance)
                 = Landin.Checking.Routine_Ready
               then
                  declare
                     Template : constant Res.Declaration_Id :=
                       Landin.Checking.Routine_Template_Of
                         (Types.all, Instance);
                     Previous : Landin.Checking.Routine_Instance_Id;
                  begin
                     Landin.Checking.Activate_Routine_View
                       (Types.all, Instance, Previous);
                     Collect_Any_Evidence
                       (Tree_For
                          (Res.Source_Of (Meanings.all, Template)).all);
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

         for Position in 1 .. Landin.Checking.Conformance_Count (Types.all)
         loop
            declare
               Source : constant Landin.Checking.Conformance_Id :=
                 Landin.Checking.Conformance_Identities.Nth
                   (Types.all, Position);
               Actual : constant Landin.Checking.Actual_Key :=
                 Landin.Checking.Conformance_Target (Types.all, Source);
               Seen : Boolean_Array
                 (1 .. Positive'Max
                   (1, Landin.Checking.Concept_Count (Types.all))) :=
                     [others => False];
            begin
               Evidence (Position) :=
                 IR.Add_Evidence (Unit.all, Evidence_Shape (Actual));
               for Provider_Position in
                 1 .. Landin.Checking.Conformance_Entry_Count
                        (Types.all, Source)
               loop
                  Add_Provider
                    (Evidence (Position), Source, Provider_Position);
               end loop;

               if Used_Any_Evidence (Position) then
                  Any_Evidence (Position) :=
                    IR.Add_Evidence
                      (Unit.all, Evidence_Shape (Actual), Erased => True);
                  Add_Closure (Any_Evidence (Position), Source, Seen);
               end if;
            end;
         end loop;
      end;

      --  D161's anonymous literal data must be registered before pass two
      --  starts filling declaration items, then completed after those
      --  earlier items: every item's values occupy one contiguous IR run.
      --  The base view covers
      --  ordinary declarations and anonymous functions; each ready generic
      --  view covers contextual literals whose referent was substituted.
      declare
         procedure Register_Texts (Of_Tree : Syn.Tree);

         procedure Register_Texts (Of_Tree : Syn.Tree) is
         begin
            for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Of_Tree) loop
               if Syn.Kind (Of_Tree, Node)
                    in Syn.Text_Literal | Syn.Raw_Literal
                 and then Landin.Checking.Type_Of
                   (Types.all, Of_Tree, Node)
                     in Ty.Pointer_Value | Ty.Slice_Value
               then
                  Register_Text_Datum (Of_Tree, Node);
               end if;
            end loop;
         end Register_Texts;
      begin
         for Index in 1 .. Source_Count (Context) loop
            Register_Texts (Tree_For (Nth_Source (Context, Index)).all);
         end loop;

         for Position in
           1 .. Landin.Checking.Routine_Instance_Count (Types.all)
         loop
            declare
               Instance : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Routine_Identities.Nth
                   (Types.all, Position);
            begin
               if Landin.Checking.Routine_State_Of (Types.all, Instance)
                 = Landin.Checking.Routine_Ready
               then
                  declare
                     Template : constant Res.Declaration_Id :=
                       Landin.Checking.Routine_Template_Of
                         (Types.all, Instance);
                     Previous : Landin.Checking.Routine_Instance_Id;
                  begin
                     Landin.Checking.Activate_Routine_View
                       (Types.all, Instance, Previous);
                     Register_Texts
                       (Tree_For
                          (Res.Source_Of (Meanings.all, Template)).all);
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
      end;

      --  Resolve D24/D34/D66 initial images after every item identity and
      --  shape exists, but before emitting any declaration's instructions.
      --  Static dependencies can follow later declarations [1740] without
      --  disturbing item-ordered block and value runs.  Array datums keep
      --  their per-position or compact repetition folds; an aggregate literal
      --  carries one fold per declaration-order field.  A direct storage name
      --  follows D21/D60/D61's chain while preserving the source image.  An
      --  absent or explicit zero image stays reserved in `.bss`; a written
      --  image reaches `.data`.
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


         procedure Fold_Constant
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Value   : out Ty.Folded;
            Known   : out Boolean);

         procedure Fold_Scalar_Datum
           (Id    : Res.Declaration_Id;
            Value : out Ty.Folded;
            Known : out Boolean);

         type Static_Selection is record
            Item  : IR.Item_Id := IR.No_Item;
            Shape : IR.Field_Shape;
            Image : IR.Aggregate_Field_Image;
            Root  : Boolean := False;
         end record;

         function Selected_Image
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Static_Selection;

         --  All static dependencies, including callable leaf selections,
         --  share the same cycle guard and declaration-owned image cache.
         procedure Resolve_Image (Id : Res.Declaration_Id);

         --  A checked extraction of an immediately constructed identity
         --  reads the original image; no temporary module datum is needed.
         function Representation_Source
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

         function Representation_Source
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
         is
            Conversion : constant Landin.Checking.Nominal_Type_Id :=
              (if Node = Syn.No_Node then Landin.Checking.No_Nominal_Type
               else Landin.Checking.Distinct_Conversion_Of
                 (Types.all, Of_Tree, Node));
         begin
            if Conversion /= Landin.Checking.No_Nominal_Type
              and then (Type_At (Of_Tree, Node) /= Ty.Aggregate
                or else Landin.Checking.Nominal_Of
                  (Types.all, Of_Tree, Node) /= Conversion)
            then
               declare
                  Inner : constant Syn.Node_Id :=
                    Syn.Nth_Argument (Of_Tree, Node, 1);
               begin
                  if Landin.Checking.Distinct_Conversion_Of
                    (Types.all, Of_Tree, Inner) = Conversion
                    and then Type_At (Of_Tree, Inner) = Ty.Aggregate
                    and then Landin.Checking.Nominal_Of
                      (Types.all, Of_Tree, Inner) = Conversion
                  then
                     return Representation_Source
                       (Of_Tree, Syn.Nth_Argument (Of_Tree, Inner, 1));
                  end if;
               end;
            end if;
            return Node;
         end Representation_Source;

         function Static_Field_Target
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return IR.Item_Id;

         function Static_Field_Target
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return IR.Item_Id
         is
         begin
            if Representation_Source (Of_Tree, Value) /= Value then
               return Static_Field_Target
                 (Of_Tree, Representation_Source (Of_Tree, Value));
            elsif Landin.Checking.Distinct_Conversion_Of
              (Types.all, Of_Tree, Value)
                /= Landin.Checking.No_Nominal_Type
            then
               return Selected_Image (Of_Tree, Value).Image.Target;
            end if;
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
                     Resolve_Image (Source_Id);
                     return IR.Function_Target
                       (Unit.all, IR.Item_For (Unit.all, Source_Id));
                  end if;
               end;
            elsif Syn.Kind (Of_Tree, Value)
              in Syn.Member_Selection | Syn.Element_Index
            then
               return Selected_Image (Of_Tree, Value).Image.Target;
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

         --  R4.21: the one folder, instantiated with this stage's answers.
         --  A chain that comes back to its own binding is declined here
         --  without a word: the checker has already reported it.
         function Snapshot_For
           (Id : Landin.Source.Source_Id) return Landin.Source.Snapshot
           is (Landin.Stages.Source (Context, Id));

         function Float_Special_Type_At
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
           is (if Is_Float_Special (Of_Tree, Node)
               then Type_At (Of_Tree, Node) else Ty.Ill_Typed);

         function Enter_Fold (Means : Res.Declaration_Id) return Boolean;
         procedure Leave_Fold (Means : Res.Declaration_Id);

         function Enter_Fold (Means : Res.Declaration_Id) return Boolean is
         begin
            if Means not in Numbered or else Folding (Means) then
               return False;
            end if;
            Folding (Means) := True;
            return True;
         end Enter_Fold;

         procedure Leave_Fold (Means : Res.Declaration_Id) is
         begin
            if Means in Numbered then
               Folding (Means) := False;
            end if;
         end Leave_Fold;

         package Folder is new Landin.Stages.Folding
           (Types              => Types,
            Meanings           => Meanings,
            Facts              => Facts,
            Snapshot_Of        => Snapshot_For,
            Tree_For           => Tree_For,
            Conversion_Target  => Conversion_Scalar,
            Character_Value    => Character_Magnitude,
            Float_Special_Type => Float_Special_Type_At,
            Float_Special_Bits => Float_Special_At,
            Enter              => Enter_Fold,
            Leave              => Leave_Fold);

         procedure Fold_Constant
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Value   : out Ty.Folded;
            Known   : out Boolean)
         is
            Overflowed : Boolean;
         begin
            Folder.Fold (Of_Tree, Node, 0, Value, Known, Overflowed);
            --  An image holds an answer or nothing; an overflow the
            --  checker let through is nothing here, and the caller says so.
            Known := Known and then not Overflowed;
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

         function Selected_Image
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Static_Selection
         is
            Result : Static_Selection;
            Conversion : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Distinct_Conversion_Of
                (Types.all, Of_Tree, Node);
         begin
            if Representation_Source (Of_Tree, Node) /= Node then
               return Selected_Image
                 (Of_Tree, Representation_Source (Of_Tree, Node));
            end if;
            if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference then
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  Resolve_Image (Id);
                  Result.Item := IR.Item_For (Unit.all, Id);
                  Result.Shape := Neutral_Value_Shape (Of_Tree, Node);
                  Result.Root := True;
                  if IR.Has_Recursive_Array_Image (Unit.all, Result.Item) then
                     Result.Image := IR.Array_Image_Of (Unit.all, Result.Item);
                  end if;
                  return Result;
               end;
            end if;
            Result := Selected_Image
              (Of_Tree,
               (if Conversion /= Landin.Checking.No_Nominal_Type
                then Syn.Nth_Argument (Of_Tree, Node, 1)
                else Syn.Target_Of (Of_Tree, Node)));
            if Conversion /= Landin.Checking.No_Nominal_Type
              or else Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            then
               declare
                  Field : constant Positive :=
                    (if Conversion /= Landin.Checking.No_Nominal_Type
                     then 1 else Positive
                       (Landin.Checking.Field_Index
                          (Types.all, Of_Tree, Node)));
                  Child : constant IR.Field_Shape :=
                    IR.Nth_Aggregate_Field (Unit.all, Result.Shape, Field);
               begin
                  if not IR.Has_Image (Unit.all, Result.Item) then
                     Result.Image := (others => <>);
                  elsif Result.Root then
                     Result.Image :=
                       IR.Field_Image_Of (Unit.all, Result.Item, Field);
                     if Child.Kind = IR.Scalar_Field_Shape then
                        Result.Image.Value :=
                          IR.Nth_Field_Image (Unit.all, Result.Item, Field);
                     end if;
                  elsif Result.Image.Form = IR.Nested then
                     Result.Image := IR.Descendant_Image_Of
                       (Unit.all, Result.Item, Result.Image, Field);
                  elsif Result.Image.Form /= IR.Absent then
                     raise Landin.Compiler_Defect with
                       "a static member selected a non-aggregate image";
                  end if;
                  Result.Shape := Child;
               end;
            elsif Syn.Kind (Of_Tree, Node) = Syn.Element_Index then
               declare
                  Index : Ty.Folded;
                  Known : Boolean;
               begin
                  Fold_Constant
                    (Of_Tree, Syn.Index_Of (Of_Tree, Node), Index, Known);
                  if not Known or else Index < 0
                    or else Index >= Ty.Folded (Result.Shape.Length)
                  then
                     raise Landin.Compiler_Defect with
                       "a static array selection has no checked index";
                  end if;
                  if not IR.Has_Image (Unit.all, Result.Item) then
                     Result.Image := (others => <>);
                  elsif Result.Root and then not IR.Has_Recursive_Array_Image
                    (Unit.all, Result.Item)
                  then
                     Result.Image :=
                       (Value => IR.Nth_Image
                          (Unit.all, Result.Item,
                           IR.Part_Position (Index + 1)),
                        others => <>);
                  elsif Result.Image.Form = IR.Element_Sequence then
                     Result.Image := IR.Descendant_Image_Of
                       (Unit.all, Result.Item, Result.Image,
                        (if Index < Ty.Folded (Result.Image.Count - 1)
                         then Positive (Index + 1) else Result.Image.Count));
                  elsif Result.Image.Form = IR.Finite
                    or else (Result.Image.Form = IR.Hybrid
                             and then Index < Ty.Folded (Result.Image.Count))
                  then
                     Result.Image :=
                       (Value => IR.Nth_Descriptor_Element
                          (Unit.all, Result.Item, Result.Image,
                           IR.Part_Position (Index + 1)), others => <>);
                  elsif Result.Image.Form in IR.Repeated | IR.Hybrid then
                     Result.Image :=
                       (Value => Result.Image.Value, others => <>);
                  elsif Result.Image.Form /= IR.Absent then
                     raise Landin.Compiler_Defect with
                       "a static index selected a non-array image";
                  end if;
                  Result.Shape :=
                    IR.Array_Element_Shape (Unit.all, Result.Shape);
               end;
            else
               raise Landin.Compiler_Defect with
                 "a static selection has no stored source";
            end if;
            Result.Root := False;
            return Result;
         end Selected_Image;

         function Is_C_String_Value
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return Boolean;

         function Static_Address_Target
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return IR.Item_Id;

         function Is_C_String_Value
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return Boolean
         is
            Reference : constant Landin.Checking.Reference_Id :=
              Landin.Checking.Reference_Of (Types.all, Of_Tree, Value);
         begin
            return Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
                     = Ty.Pointer_Value
              and then Reference /= Landin.Checking.No_Reference
              and then Landin.Checking.Descriptor_Of
                (Types.all, Reference).View = Ty.C_String_View;
         end Is_C_String_Value;

         function Static_Address_Target
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id) return IR.Item_Id
         is
         begin
            if Representation_Source (Of_Tree, Value) /= Value then
               return Static_Address_Target
                 (Of_Tree, Representation_Source (Of_Tree, Value));
            elsif Landin.Checking.Distinct_Conversion_Of
              (Types.all, Of_Tree, Value)
                /= Landin.Checking.No_Nominal_Type
            then
               return Selected_Image (Of_Tree, Value).Image.Target;
            end if;
            if Syn.Kind (Of_Tree, Value)
                 in Syn.Text_Literal | Syn.Raw_Literal
            then
               return Text_Datum (Of_Tree, Value);
            elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
               return IR.No_Item;
            elsif Syn.Kind (Of_Tree, Value) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Value)
                           = Res.Bound
            then
               declare
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Value);
                  Source_Item : constant IR.Item_Id :=
                    IR.Item_For (Unit.all, Source_Id);
               begin
                  Resolve_Image (Source_Id);
                  return IR.Address_Target (Unit.all, Source_Item);
               end;
            end if;

            raise Landin.Compiler_Defect with
              "a static cstring field has no data target";
         end Static_Address_Target;

         function Static_Slice_Image
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id)
            return IR.Aggregate_Field_Image;

         function Static_Slice_Image
           (Of_Tree : Syn.Tree; Value : Syn.Node_Id)
            return IR.Aggregate_Field_Image
         is
            Result : IR.Aggregate_Field_Image :=
              (Slice => True, Slice_Element => Slice_Shape (Of_Tree, Value),
               others => <>);
         begin
            if Representation_Source (Of_Tree, Value) /= Value then
               return Static_Slice_Image
                 (Of_Tree, Representation_Source (Of_Tree, Value));
            elsif Landin.Checking.Distinct_Conversion_Of
              (Types.all, Of_Tree, Value)
                /= Landin.Checking.No_Nominal_Type
              or else Syn.Kind (Of_Tree, Value)
                in Syn.Member_Selection | Syn.Element_Index
            then
               return Selected_Image (Of_Tree, Value).Image;
            elsif Syn.Kind (Of_Tree, Value) = Syn.Empty_Slice_Literal then
               return Result;
            elsif Syn.Kind (Of_Tree, Value)
              in Syn.Text_Literal | Syn.Raw_Literal
            then
               Result.Target := Text_Datum (Of_Tree, Value);
               Result.Value := Ty.Folded
                 (IR.Array_Length (Unit.all, Result.Target) - 1);
            elsif Syn.Kind (Of_Tree, Value) = Syn.Name_Reference then
               declare
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Value);
                  Item : constant IR.Item_Id :=
                    IR.Item_For (Unit.all, Source_Id);
               begin
                  Resolve_Image (Source_Id);
                  Result.Target := IR.Slice_Image_Source (Unit.all, Item);
                  Result.Slice_First := IR.Slice_Image_First (Unit.all, Item);
                  Result.Value :=
                    Ty.Folded (IR.Slice_Image_Length (Unit.all, Item));
               end;
            elsif Syn.Kind (Of_Tree, Value)
              in Syn.Inclusive_Slice | Syn.Half_Open_Slice
            then
               declare
                  Base : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Value);
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Base);
                  Lower, Upper : Ty.Folded;
                  Lower_Known, Upper_Known : Boolean;
               begin
                  Fold_Constant
                    (Of_Tree, Syn.Slice_Lower (Of_Tree, Value),
                     Lower, Lower_Known);
                  Fold_Constant
                    (Of_Tree, Syn.Slice_Upper (Of_Tree, Value),
                     Upper, Upper_Known);
                  if not Lower_Known or else not Upper_Known
                    or else Lower < 0 or else Upper < Lower
                  then
                     raise Landin.Compiler_Defect with
                       "a checked distinct slice image has no static bounds";
                  end if;
                  Result.Target := IR.Item_For (Unit.all, Source_Id);
                  Result.Slice_First := IR.Element_Total (Lower);
                  Result.Value := Upper - Lower
                    + (if Syn.Kind (Of_Tree, Value) = Syn.Inclusive_Slice
                       then 1 else 0);
               end;
            else
               raise Landin.Compiler_Defect with
                 "a checked distinct slice has no static image";
            end if;
            return Result;
         end Static_Slice_Image;

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
         procedure Set_Recursive_Image
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id);

         procedure Set_Recursive_Image
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id)
         is
            Item : constant IR.Item_Id := IR.Item_For (Unit.all, Id);
            Array_Root : constant Boolean :=
              IR.Result_Of (Unit.all, Item) = Ty.Fixed_Array;
            Top_Count : constant Natural :=
              (if Array_Root then 1 else IR.Field_Count (Unit.all, Item));
            Values : Ty.Folded_Array (1 .. Top_Count) := [others => 0];
            Descriptors : Descriptor_Vectors.Vector;
            Elements : Fold_Vectors.Vector;

            function Element_Cursor return Natural
              is (Natural (Elements.Length));

            function Descendant_Cursor return Natural
              is (Natural (Descriptors.Length) - Top_Count);

            procedure Put
              (Position : Positive; Image : IR.Aggregate_Field_Image);

            --  Empty aggregates and payloadless selected cases still own
            --  a descriptor, but reserve no child entries.
            function Reserve_Children
              (Position : Positive;
               Form     : IR.Field_Image_Form;
               Count    : Natural;
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
               Shape        : IR.Field_Shape;
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
               Count    : Natural;
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
               Shape        : IR.Field_Shape;
               Source_Image : IR.Aggregate_Field_Image;
               Position     : Positive)
            is
               Image : IR.Aggregate_Field_Image := Source_Image;
            begin
               if Image.Form = IR.Element_Sequence then
                  if Image.Count = 0 then
                     Image.Offset := Descendant_Cursor;
                     Put (Position, Image);
                  else
                     declare
                        First : constant Positive := Reserve_Children
                          (Position, IR.Element_Sequence, Image.Count,
                           Image.Value);
                        Child : constant IR.Field_Shape :=
                          IR.Array_Element_Shape (Unit.all, Shape);
                     begin
                        for Element in 1 .. Image.Count loop
                           Clone_Field
                             (Source_Item, Child,
                              IR.Descendant_Image_Of
                                (Unit.all, Source_Item, Source_Image, Element),
                              First + Element - 1);
                        end loop;
                     end;
                  end if;
                  return;
               end if;
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
                         Target => Source_Image.Target,
                         others => <>));

                  when IR.Array_Field_Shape =>
                     Clone_Array
                       (Source_Item, Shape, Source_Image, Position);

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
                               (Position, IR.Nested, Count);
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
                               (Position, IR.Selected, Count,
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
                      (Position, IR.Nested, Count);
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
                                  Target => Image.Target,
                                  others => <>));
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
               Source : constant Static_Selection :=
                 Selected_Image (Of_Tree, Given);
            begin
               if Source.Root then
                  Clone_Aggregate_Root (Source.Item, Position);
               else
                  Clone_Field
                    (Source.Item, Source.Shape, Source.Image, Position);
               end if;
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

               if Landin.Checking.Distinct_Conversion_Of
                 (Types.all, Of_Tree, Given)
                   /= Landin.Checking.No_Nominal_Type
               then
                  declare
                     Source : constant Static_Selection :=
                       Selected_Image (Of_Tree, Given);
                  begin
                     Clone_Array (Source.Item, Shape, Source.Image, Position);
                  end;
                  return;
               end if;

               if IR.Array_Element_Is_Aggregate (Unit.all, Shape)
                 and then Syn.Kind (Of_Tree, Given)
                   in Syn.Array_Literal | Syn.Array_Repetition
                      | Syn.Mixed_Array_Repetition
               then
                  declare
                     Kind : constant Syn.Node_Kind :=
                       Syn.Kind (Of_Tree, Given);
                     Child : constant IR.Field_Shape :=
                       IR.Array_Element_Shape (Unit.all, Shape);
                     Prefix : constant Natural :=
                       (if Kind = Syn.Array_Repetition then 0
                        else Syn.Element_Count (Of_Tree, Given));
                     Count : constant Natural :=
                       Prefix + (if Kind = Syn.Array_Literal then 0 else 1);
                     Repetitions : constant Ty.Folded :=
                       (if Kind = Syn.Array_Literal
                        then (if Count = 0 then 0 else 1)
                        else Ty.Folded (Shape.Length) - Ty.Folded (Prefix));
                  begin
                     if Count = 0 then
                        Put (Position,
                             (Form => IR.Element_Sequence,
                              Offset => Descendant_Cursor, others => <>));
                     else
                        declare
                           First : constant Positive := Reserve_Children
                             (Position, IR.Element_Sequence,
                              Count, Repetitions);
                        begin
                           for Element in 1 .. Prefix loop
                              Build_Field
                                (Child, Syn.Nth_Element
                                   (Of_Tree, Given, Element),
                                 First + Element - 1);
                           end loop;
                           if Kind /= Syn.Array_Literal then
                              Build_Field
                                (Child, Syn.Repeated_Element (Of_Tree, Given),
                                 First + Count - 1);
                           end if;
                        end;
                     end if;
                  end;
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
                              if IR.Has_Recursive_Array_Image
                                (Unit.all, Source_Item)
                              then
                                 Clone_Array
                                   (Source_Item, Shape,
                                    IR.Array_Image_Of (Unit.all, Source_Item),
                                    Position);
                                 return;
                              end if;
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

                  when Syn.Member_Selection | Syn.Element_Index =>
                     declare
                        Source : constant Static_Selection :=
                          Selected_Image (Of_Tree, Given);
                     begin
                        Clone_Array
                          (Source.Item, Shape, Source.Image, Position);
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
               elsif Landin.Checking.Distinct_Conversion_Of
                 (Types.all, Of_Tree, Given)
                   /= Landin.Checking.No_Nominal_Type
                 and then Landin.Checking.Nominal_Of
                   (Types.all, Of_Tree, Given)
                     = Landin.Checking.Distinct_Conversion_Of
                       (Types.all, Of_Tree, Given)
               then
                  declare
                     First : constant Positive :=
                       Reserve_Children (Position, IR.Nested, 1);
                  begin
                     Build_Field
                       (IR.Nth_Aggregate_Field (Unit.all, Shape, 1),
                        Syn.Nth_Argument (Of_Tree, Given, 1), First);
                  end;
               elsif Is_Struct_Construction (Of_Tree, Given) then
                  declare
                     Count : constant Natural :=
                       IR.Aggregate_Field_Count (Unit.all, Shape);
                     First : constant Positive :=
                       Reserve_Children
                         (Position, IR.Nested, Count);
                     type Node_Array is
                       array (Positive range <>) of Syn.Node_Id;
                     Nodes : Node_Array (1 .. Count) :=
                       [others => Construction_Fill (Of_Tree, Given)];
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
                         (Position, IR.Selected, Count,
                          Ty.Folded (Selected));
                     type Node_Array is
                       array (Positive range <>) of Syn.Node_Id;
                     Nodes : Node_Array (1 .. Count) :=
                       [others => (if Is_Case_Construction (Of_Tree, Given)
                                   then Construction_Fill (Of_Tree, Given)
                                   else Syn.No_Node)];
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
               if Representation_Source (Of_Tree, Given) /= Given then
                  Build_Field
                    (Shape, Representation_Source (Of_Tree, Given),
                     Position, Top_Field);
                  return;
               end if;
               if Given /= Syn.No_Node
                 and then Type_At (Of_Tree, Given) = Ty.Slice_Value
               then
                  Put (Position, Static_Slice_Image (Of_Tree, Given));
                  return;
               end if;
               case Shape.Kind is
                  when IR.Scalar_Field_Shape =>
                     if Given /= Syn.No_Node
                       and then Is_C_String_Value (Of_Tree, Given)
                     then
                        Target := Static_Address_Target (Of_Tree, Given);
                     elsif Shape.Signature /= IR.No_Signature then
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
                         Target => Target,
                         others => <>));
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
            if Representation_Source (Of_Tree, Literal) /= Literal then
               Set_Recursive_Image
                 (Id, Of_Tree, Representation_Source (Of_Tree, Literal));
               return;
            end if;
            for Field in 1 .. Top_Count loop
               Descriptors.Append
                 (IR.Aggregate_Field_Image'(others => <>));
            end loop;

            if Array_Root then
               Build_Array (IR.Whole_Array_Shape (Unit.all, Item), Literal, 1);
            elsif Landin.Checking.Distinct_Conversion_Of
              (Types.all, Of_Tree, Literal)
                /= Landin.Checking.No_Nominal_Type
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Literal)
                  = Landin.Checking.Distinct_Conversion_Of
                    (Types.all, Of_Tree, Literal)
            then
               Build_Field
                 (IR.Nth_Field_Shape (Unit.all, Item, 1),
                  Syn.Nth_Argument (Of_Tree, Literal, 1), 1, Top_Field => 1);
            elsif not Is_Struct_Construction (Of_Tree, Literal) then
               declare
                  Source : constant Static_Selection :=
                    Selected_Image (Of_Tree, Literal);
               begin
                  for Field in 1 .. Top_Count loop
                     declare
                        Shape : constant IR.Field_Shape :=
                          IR.Nth_Field_Shape (Unit.all, Item, Field);
                        Image : IR.Aggregate_Field_Image := (others => <>);
                     begin
                        if IR.Has_Image (Unit.all, Source.Item) then
                           if Source.Root then
                              Image := IR.Field_Image_Of
                                (Unit.all, Source.Item, Field);
                              if Shape.Kind = IR.Scalar_Field_Shape then
                                 Image.Value := IR.Nth_Field_Image
                                   (Unit.all, Source.Item, Field);
                              end if;
                           elsif Source.Image.Form = IR.Nested then
                              Image := IR.Descendant_Image_Of
                                (Unit.all, Source.Item, Source.Image, Field);
                           end if;
                        end if;
                        Clone_Field (Source.Item, Shape, Image, Field);
                        if Shape.Kind = IR.Scalar_Field_Shape then
                           Image := Descriptors (Field);
                           Values (Field) := Image.Value;
                           Image.Value := 0;
                           Put (Field, Image);
                        end if;
                     end;
                  end loop;
               end;
            else
               declare
                  type Node_Array is
                    array (Positive range <>) of Syn.Node_Id;
                  Nodes : Node_Array (1 .. Top_Count) :=
                    [others => Construction_Fill (Of_Tree, Literal)];
               begin
                  for Written in
                    1 .. Construction_Field_Count (Of_Tree, Literal)
                  loop
                     declare
                        Label : constant Syn.Node_Id :=
                          Nth_Construction_Field
                            (Of_Tree, Literal, Written);
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
            end if;

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
               if Array_Root then
                  if Images (1).Form /= IR.Absent then
                     IR.Set_Array_Image
                       (Unit.all, Item, Images (1), Descendants, Folds);
                  end if;
               else
                  IR.Set_Aggregate_Image
                    (Unit.all, Item, Values, Images, Descendants, Folds);
               end if;
               Made (Id) := True;
            end;
         end Set_Recursive_Image;

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
               elsif Shape.Kind = IR.Array_Field_Shape then
                  return IR.Array_Element_Is_Aggregate (Unit.all, Shape);
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

            function Has_Value_Fill (Node : Syn.Node_Id) return Boolean;

            function Has_Value_Fill (Node : Syn.Node_Id) return Boolean is
            begin
               if Node = Syn.No_Node then
                  return False;
               end if;
               if Syn.Kind (Of_Tree, Node) in Syn.Struct_Literal
                 | Syn.Labeled_Application | Syn.Call
               then
                  declare
                     Fill : constant Syn.Node_Id :=
                       Construction_Fill (Of_Tree, Node);
                  begin
                     if Fill /= Syn.No_Node
                       and then Syn.Kind (Of_Tree, Fill) /= Syn.Zeroed_Literal
                     then
                        return True;
                     end if;
                  end;
               end if;
               for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
                  if Has_Value_Fill (Syn.Slot (Of_Tree, Node, Slot)) then
                     return True;
                  end if;
               end loop;
               return Syn.Kind (Of_Tree, Node)
                        in Syn.Call | Syn.Labeled_Application
                 and then Has_Value_Fill (Syn.Recovery_Of (Of_Tree, Node));
            end Has_Value_Fill;

            function Needs_Recursive_Image return Boolean;

            function Needs_Recursive_Image return Boolean is
            begin
               if Has_Value_Fill (Literal)
                 or else Has_Distinct_Conversion (Of_Tree, Literal)
               then
                  return True;
               end if;
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
               Set_Recursive_Image
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
                           if Is_C_String_Value (Of_Tree, Value)
                           then
                              Images (Which).Target :=
                                Static_Address_Target (Of_Tree, Value);
                           elsif Shape.Signature /= IR.No_Signature then
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
                                          if Is_C_String_Value
                                            (Of_Tree, Given)
                                          then
                                             Image.Target :=
                                               Static_Address_Target
                                                 (Of_Tree, Given);
                                          elsif Leaf.Signature /=
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
                        elsif Landin.Checking.Field_Kind_Of
                          (Types.all,
                           Landin.Checking.Nominal_Of (Types.all, Id), Which)
                            = Landin.Checking.Reference_Field
                          and then Landin.Checking.Descriptor_Of
                            (Types.all,
                             Landin.Checking.Field_Shape_Of
                               (Types.all,
                                Landin.Checking.Nominal_Of (Types.all, Id),
                                Which).Reference).Kind = Ty.Slice_Value
                        then
                           declare
                              Element : constant IR.Field_Shape :=
                                Slice_Shape (Of_Tree, Value);
                           begin
                              Images (Which).Slice := True;
                              Images (Which).Slice_Element := Element;
                              if Syn.Kind (Of_Tree, Value)
                                   = Syn.Empty_Slice_Literal
                              then
                                 Images (Which).Value := 0;
                              elsif Syn.Kind (Of_Tree, Value)
                                      in Syn.Text_Literal | Syn.Raw_Literal
                              then
                                 Images (Which).Target :=
                                   Text_Datum (Of_Tree, Value);
                                 Images (Which).Slice_First := 0;
                                 Images (Which).Value := Ty.Folded
                                   (IR.Array_Length
                                      (Unit.all, Images (Which).Target) - 1);
                              elsif Syn.Kind (Of_Tree, Value)
                                in Syn.Inclusive_Slice | Syn.Half_Open_Slice
                              then
                                 declare
                                    Base : constant Syn.Node_Id :=
                                      Syn.Target_Of (Of_Tree, Value);
                                    Source_Id : constant Res.Declaration_Id :=
                                      Res.Bound_To
                                        (Meanings.all, Of_Tree, Base);
                                    Lower, Upper : Ty.Folded;
                                    Lower_Known, Upper_Known : Boolean;
                                 begin
                                    Fold_Constant
                                      (Of_Tree,
                                       Syn.Slice_Lower (Of_Tree, Value),
                                       Lower, Lower_Known);
                                    Fold_Constant
                                      (Of_Tree,
                                       Syn.Slice_Upper (Of_Tree, Value),
                                       Upper, Upper_Known);
                                    if not Lower_Known or else not Upper_Known
                                      or else Lower < 0 or else Upper < Lower
                                    then
                                       raise Landin.Compiler_Defect with
                                         "a static slice field bound did not"
                                         & " fold";
                                    end if;
                                    Images (Which).Target :=
                                      IR.Item_For (Unit.all, Source_Id);
                                    Images (Which).Slice_First :=
                                      IR.Element_Total (Lower);
                                    Images (Which).Value :=
                                      Upper - Lower
                                      + (if Syn.Kind (Of_Tree, Value)
                                              = Syn.Inclusive_Slice
                                         then 1 else 0);
                                 end;
                              else
                                 raise Landin.Compiler_Defect with
                                   "a static slice field has no image form";
                              end if;
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

                  when IR.Selected | IR.Nested | IR.Element_Sequence =>
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
            if IR.Has_Recursive_Array_Image (Unit.all, Source_Item) then
               declare
                  Count : constant Natural :=
                    IR.Aggregate_Field_Image_Count (Unit.all, Source_Item) - 1;
                  Children : IR.Aggregate_Field_Image_Array (1 .. Count);
                  Elements : Ty.Folded_Array (1 .. Natural (Length));
               begin
                  --  Whole-run copies retain item-relative offsets.  Only
                  --  extracting a subtree needs Clone_Field's fresh rebasing.
                  for Child in Children'Range loop
                     Children (Child) := IR.Nth_Image_Descriptor
                       (Unit.all, Source_Item, Child + 1);
                  end loop;
                  for Element in Elements'Range loop
                     Elements (Element) := IR.Nth_Aggregate_Image_Element
                       (Unit.all, Source_Item, IR.Part_Position (Element));
                  end loop;
                  IR.Set_Array_Image
                    (Unit.all, IR.Item_For (Unit.all, Destination),
                     IR.Array_Image_Of (Unit.all, Source_Item),
                     Children, Elements);
                  Made (Destination) := True;
               end;
               return;
            end if;
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
                         (Unit.all, Source_Item, Position).Form
                           in IR.Nested | IR.Element_Sequence;
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
                  raise Landin.Compiler_Defect with
                    "a checked static image contains a dependency cycle";
               when Unseen =>
                  null;
            end case;

            Where (Id) := Visiting;

            if Landin.Checking.Type_Of (Types.all, Id)
              in Ty.Scalar_Name | Ty.Atom_Value
              and then Landin.Checking.Type_Of (Types.all, Id) /= Ty.Bool
              and then Has_Distinct_Conversion (Their_Tree.all, Value)
            then
               Fold_Constant
                 (Their_Tree.all, Value,
                  Distinct_Image (Id), Has_Distinct_Image (Id));
               if not Has_Distinct_Image (Id) then
                  raise Landin.Compiler_Defect with
                    "a checked scalar representation image did not fold";
               end if;
               Where (Id) := Resolved;
               return;
            end if;

            if Landin.Checking.Type_Of (Types.all, Id) = Ty.Function_Value then
               declare
                  Item : constant IR.Item_Id := IR.Item_For (Unit.all, Id);
                  Target : constant IR.Item_Id :=
                    Static_Field_Target (Their_Tree.all, Value);
               begin
                  if not IR.Holds (Unit.all, Target)
                    or else IR.Kind_Of (Unit.all, Target) /= IR.Routine
                  then
                     raise Landin.Compiler_Defect with
                       "a static callback selection has no routine target";
                  end if;
                  IR.Set_Function_Target (Unit.all, Item, Target);
                  Made (Id) := True;
               end;
               Where (Id) := Resolved;
               return;
            end if;

            if Value /= Syn.No_Node
              and then Landin.Checking.Distinct_Conversion_Of
                (Types.all, Their_Tree.all, Value)
                  /= Landin.Checking.No_Nominal_Type
              and then Landin.Checking.Type_Of (Types.all, Id)
                in Ty.Aggregate | Ty.Fixed_Array
            then
               Set_Recursive_Image (Id, Their_Tree.all, Value);
               Where (Id) := Resolved;
               return;
            end if;

            if Value /= Syn.No_Node
              and then Landin.Checking.Distinct_Conversion_Of
                (Types.all, Their_Tree.all, Value)
                  /= Landin.Checking.No_Nominal_Type
            then
               if Landin.Checking.Type_Of (Types.all, Id) = Ty.Slice_Value then
                  declare
                     Image : constant IR.Aggregate_Field_Image :=
                       Static_Slice_Image (Their_Tree.all, Value);
                  begin
                     IR.Set_Slice_Image
                       (Unit.all, IR.Item_For (Unit.all, Id),
                        Image.Slice_Element, IR.Element_Total (Image.Value),
                        Image.Target, Image.Slice_First);
                  end;
                  Made (Id) := True;
                  Where (Id) := Resolved;
                  return;
               elsif Is_C_String_Value (Their_Tree.all, Value) then
                  IR.Set_Address_Target
                    (Unit.all, IR.Item_For (Unit.all, Id),
                     Static_Address_Target (Their_Tree.all, Value));
                  Made (Id) := True;
                  Where (Id) := Resolved;
                  return;
               end if;
            end if;

            if (Landin.Checking.Type_Of (Types.all, Id) = Ty.Fixed_Array
                and then IR.Array_Element_Is_Aggregate
                  (Unit.all, IR.Whole_Array_Shape
                     (Unit.all, IR.Item_For (Unit.all, Id))))
              or else
                (Landin.Checking.Type_Of (Types.all, Id)
                   in Ty.Fixed_Array | Ty.Aggregate
                 and then Value /= Syn.No_Node
                 and then Syn.Kind (Their_Tree.all, Value)
                   in Syn.Member_Selection | Syn.Element_Index)
            then
               Set_Recursive_Image (Id, Their_Tree.all, Value);
               Where (Id) := Resolved;
               return;
            end if;

            if Landin.Checking.Type_Of (Types.all, Id) = Ty.Bool then
               declare
                  Held  : Ty.Folded;
                  Known : Boolean;
               begin
                  Fold_Scalar_Datum (Id, Held, Known);
                  if not Known or else Held not in 0 | 1 then
                     raise Landin.Compiler_Defect with
                       "a checked module bool did not fold to its image";
                  end if;
                  IR.Set_Bool_Image
                    (Unit.all, IR.Item_For (Unit.all, Id), Held);
                  Made (Id) := True;
               end;
               Where (Id) := Resolved;
               return;
            end if;

            if Landin.Checking.Type_Of (Types.all, Id) = Ty.Pointer_Value
              and then Landin.Checking.Descriptor_Of
                (Types.all, Landin.Checking.Reference_Of (Types.all, Id)).View
                  = Ty.C_String_View
            then
               if Value /= Syn.No_Node
                 and then Syn.Kind (Their_Tree.all, Value)
                    in Syn.Text_Literal | Syn.Raw_Literal
               then
                  IR.Set_Address_Target
                    (Unit.all, IR.Item_For (Unit.all, Id),
                     Text_Datum (Their_Tree.all, Value));
                  Made (Id) := True;
               elsif Value /= Syn.No_Node
                 and then Syn.Kind (Their_Tree.all, Value)
                            = Syn.Name_Reference
                 and then Res.Verdict_Of
                   (Meanings.all, Their_Tree.all, Value) = Res.Bound
               then
                  declare
                     Source_Id : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Their_Tree.all, Value);
                  begin
                     Resolve_Image (Source_Id);
                     if IR.Address_Target
                       (Unit.all, IR.Item_For (Unit.all, Source_Id))
                         /= IR.No_Item
                     then
                        IR.Set_Address_Target
                          (Unit.all, IR.Item_For (Unit.all, Id),
                           IR.Address_Target
                             (Unit.all, IR.Item_For (Unit.all, Source_Id)));
                        Made (Id) := True;
                     end if;
                  end;
               end if;
               Where (Id) := Resolved;
               return;
            end if;

            if Landin.Checking.Type_Of (Types.all, Id) = Ty.Slice_Value then
               declare
                  Element : constant IR.Field_Shape :=
                    Slice_Shape (Their_Tree.all, Value);
               begin
                  if Syn.Kind (Their_Tree.all, Value)
                       = Syn.Empty_Slice_Literal
                  then
                     IR.Set_Slice_Image
                       (Unit.all, IR.Item_For (Unit.all, Id), Element, 0);
                     Made (Id) := True;
                  elsif Syn.Kind (Their_Tree.all, Value)
                          in Syn.Text_Literal | Syn.Raw_Literal
                  then
                     declare
                        Datum : constant IR.Item_Id :=
                          Text_Datum (Their_Tree.all, Value);
                     begin
                        IR.Set_Slice_Image
                          (Unit.all, IR.Item_For (Unit.all, Id), Element,
                           IR.Array_Length (Unit.all, Datum) - 1,
                           Source => Datum, First => 0);
                        Made (Id) := True;
                     end;
                  elsif Syn.Kind (Their_Tree.all, Value)
                    in Syn.Inclusive_Slice | Syn.Half_Open_Slice
                  then
                     declare
                        Base : constant Syn.Node_Id :=
                          Syn.Target_Of (Their_Tree.all, Value);
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Their_Tree.all, Base);
                        Lower, Upper : Ty.Folded;
                        Lower_Known, Upper_Known : Boolean;
                     begin
                        Fold_Constant
                          (Their_Tree.all,
                           Syn.Slice_Lower (Their_Tree.all, Value),
                           Lower, Lower_Known);
                        Fold_Constant
                          (Their_Tree.all,
                           Syn.Slice_Upper (Their_Tree.all, Value),
                           Upper, Upper_Known);
                        if not Lower_Known or else not Upper_Known
                          or else Lower < 0 or else Upper < Lower
                        then
                           raise Landin.Compiler_Defect with
                             "a static slice bound the checker accepted"
                             & " did not fold";
                        end if;
                        IR.Set_Slice_Image
                          (Unit.all, IR.Item_For (Unit.all, Id), Element,
                           IR.Element_Total
                             (Upper - Lower
                              + (if Syn.Kind (Their_Tree.all, Value)
                                      = Syn.Inclusive_Slice
                                 then 1 else 0)),
                           IR.Item_For (Unit.all, Source_Id),
                           IR.Element_Total (Lower));
                        Made (Id) := True;
                     end;
                  elsif Syn.Kind (Their_Tree.all, Value)
                          = Syn.Name_Reference
                  then
                     declare
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To
                            (Meanings.all, Their_Tree.all, Value);
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id)
                          and then IR.Has_Slice_Image
                            (Unit.all, IR.Item_For (Unit.all, Source_Id))
                        then
                           IR.Set_Slice_Image
                             (Unit.all, IR.Item_For (Unit.all, Id), Element,
                              IR.Slice_Image_Length
                                (Unit.all,
                                 IR.Item_For (Unit.all, Source_Id)),
                              IR.Slice_Image_Source
                                (Unit.all,
                                 IR.Item_For (Unit.all, Source_Id)),
                              IR.Slice_Image_First
                                (Unit.all,
                                 IR.Item_For (Unit.all, Source_Id)));
                           Made (Id) := True;
                        end if;
                     end;
                  end if;
               end;
               Where (Id) := Resolved;
               return;
            end if;

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
                          in Ty.Scalar_Name | Ty.Fixed_Array | Ty.Aggregate
                             | Ty.Atom_Value | Ty.Pointer_Value
                             | Ty.Slice_Value | Ty.Function_Value
               then
                  Resolve_Image (Id);
               end if;
            end loop;
         end if;
      end Resolve_Module_Images;

      --  Pass two: fill every active item in the same declaration order.
      declare
         procedure Lower_Declaration
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

         procedure Lower_Declaration
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
         begin
            case Syn.Kind (Of_Tree, Node) is
               when Syn.Function_Declaration =>
                  if Syn.Generic_Formal_Count (Of_Tree, Node) = 0
                    and then not Syn.Is_External (Of_Tree, Node)
                  then
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

      for Index in 1 .. Bound_Provider_Count loop
         declare
            Entry_Point : Bound_Provider renames Bound_Providers (Index);
            Template : constant Res.Declaration_Id :=
              Landin.Checking.Routine_Template_Of
                (Types.all, Entry_Point.Source);
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Template));
            Previous : Landin.Checking.Routine_Instance_Id;
         begin
            Landin.Checking.Activate_Routine_View
              (Types.all, Entry_Point.Source, Previous);
            Lower_Routine
              (Of_Tree.all, Res.Node_Of (Meanings.all, Template),
               Bound_Item => Entry_Point.Item,
               Bound_Target => Entry_Point.Target);
            Landin.Checking.Restore_Routine_View (Types.all, Previous);
         exception
            when others =>
               Landin.Checking.Restore_Routine_View (Types.all, Previous);
               raise;
         end;
      end loop;

      --  Text datums were appended after every routine and declaration
      --  item.  Give them their static no-result blocks in that same item
      --  order, after every earlier item has finished its own block and
      --  instruction runs.
      for Position in 1 .. IR.Item_Count (Unit.all) loop
         declare
            Item : constant IR.Item_Id := IR.Item_Id (Position);
         begin
            if IR.Is_Read_Only (Unit.all, Item) then
               declare
                  Site : constant Landin.Provenance.Origin :=
                    IR.Origin_Of (Unit.all, Item);
                  Block : constant IR.Block_Id := IR.Add_Block
                    (Unit.all, Item, Res.Program_Scope, Site);
               begin
                  IR.Enter (Unit.all, Item, Block);
                  IR.Emit_Leave (Unit.all, Item, IR.No_Value, Site);
                  IR.Leave_Block (Unit.all, Item);
               end;
            end if;
         end;
      end loop;

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
