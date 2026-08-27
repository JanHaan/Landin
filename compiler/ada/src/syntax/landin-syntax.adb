package body Landin.Syntax is

   --  How many leading slots a kind has before its trailing run.  Written
   --  once, here: every named accessor is a position in this table, and a
   --  slot position appears nowhere else in the compiler.
   function Fixed (Of_Kind : Node_Kind) return Natural
     is (case Of_Kind is
            when Program                  => 0,
            when Error_Declaration        => 0,
            when Function_Declaration     => 2,
            --  The one slot is the type it names [1795].
            when Type_Declaration         => 1,
            when Binding                  => 2,
            when Error_Statement          => 0,
            when Assignment               => 2,
            when Increment | Decrement    => 1,
            when Discard                  => 1,
            when Return_Statement         => 1,
            when If_Statement             => 1,
            when Call                     => 1,
            when Error_Expression         => 0,
            when Name_Reference           => 0,
            --  The one slot is what it selects from; the name it selects
            --  is the node's own.
            when Member_Selection         => 1,
            --  What is indexed, and the index.
            when Element_Index            => 2,
            when Array_Literal            => 0,
            when Literal_Kind             => 0,
            --  The one slot is [1790]'s type, not an expression.
            when Size_Of | Align_Of       => 1,
            when Unary_Kind               => 1,
            when Binary_Kind              => 2,
            when Error_Type | Type_Name
               | Type_Reference           => 0,
            --  The bound and the element type.
            when Array_Type               => 2,
            --  A struct body's fields are its trailing run; a field's
            --  one slot is its type.
            when Struct_Body              => 0,
            when Field                    => 1,
            when Parameter | Named_Return => 1,
            when If_Arm                   => 2,
            when Block                    => 0);

   function Element (Of_Tree : Tree; Id : Node_Id) return Node
     is (Of_Tree.Items (Positive (Id)));

   function Run_Length (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Element (Of_Tree, Id).Slots
         - Fixed (Element (Of_Tree, Id).Kind));

   function Nth_Item
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     is (Slot (Of_Tree, Id, Fixed (Element (Of_Tree, Id).Kind) + Index));

   function Source_Of (Of_Tree : Tree) return Landin.Source.Source_Id
     is (Of_Tree.Source);

   function Node_Count (Of_Tree : Tree) return Natural
     is (Natural (Of_Tree.Items.Length));

   function Last_Node (Of_Tree : Tree) return Node_Id
     is (Node_Id (Of_Tree.Items.Length));

   function Kind (Of_Tree : Tree; Id : Node_Id) return Node_Kind
     is (Element (Of_Tree, Id).Kind);

   function Root (Of_Tree : Tree) return Node_Id
     is (Last_Node (Of_Tree));

   function Where (Of_Tree : Tree; Id : Node_Id) return Landin.Source.Span
     is (Element (Of_Tree, Id).Extent);

   function Anchor (Of_Tree : Tree; Id : Node_Id) return Landin.Source.Span
     is (Element (Of_Tree, Id).Anchor);

   function Origin (Of_Tree : Tree; Id : Node_Id)
     return Landin.Provenance.Origin
     is (Source => Of_Tree.Source,
         Where  => Element (Of_Tree, Id).Extent);

   function Name (Of_Tree : Tree; Id : Node_Id)
     return Landin.Source.Names.Name_Id
     is (Element (Of_Tree, Id).Name);

   function Base (Of_Tree : Tree; Id : Node_Id)
     return Landin.Tokens.Integer_Base
     is (Element (Of_Tree, Id).Base);

   function Digit_Span (Of_Tree : Tree; Id : Node_Id)
     return Landin.Source.Span
     is (Element (Of_Tree, Id).Digit_Run);

   function Is_Public (Of_Tree : Tree; Id : Node_Id) return Boolean
     is (Element (Of_Tree, Id).Exported);

   function Is_Mutable (Of_Tree : Tree; Id : Node_Id) return Boolean
     is (Element (Of_Tree, Id).Mutable);

   function Is_Sound (Of_Tree : Tree; Id : Node_Id) return Boolean
     is (Element (Of_Tree, Id).Sound);

   function Is_Sound (Of_Tree : Tree) return Boolean
     is (Is_Sound (Of_Tree, Root (Of_Tree)));

   function Slot_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Element (Of_Tree, Id).Slots);

   function Slot (Of_Tree : Tree; Id : Node_Id; Index : Positive)
     return Node_Id
     is (Of_Tree.Links (Element (Of_Tree, Id).First_Slot + Index));

   function Declaration_Count (Of_Tree : Tree) return Natural
     is (Run_Length (Of_Tree, Root (Of_Tree)));

   function Nth_Declaration (Of_Tree : Tree; Index : Positive)
     return Node_Id
     is (Nth_Item (Of_Tree, Root (Of_Tree), Index));

   function Declared_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Bound_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Index_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 2));

   function Element_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 2));

   function Measured_Type (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Value_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (case Kind (Of_Tree, Id) is
            when Binding | Assignment => Slot (Of_Tree, Id, 2),
            when others               => Slot (Of_Tree, Id, 1));

   function Target_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Condition_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   --  A function's return is slot 1 and an arm's condition is slot 1, so
   --  both put what they run in slot 2.  That is a coincidence the layout
   --  table above is allowed to have and callers never see.
   function Body_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 2));

   function Return_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Parameter_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Run_Length (Of_Tree, Id));

   function Nth_Parameter
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     is (Nth_Item (Of_Tree, Id, Index));

   function Else_Body (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Arm_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Run_Length (Of_Tree, Id));

   function Nth_Arm (Of_Tree : Tree; Id : Node_Id; Index : Positive)
     return Node_Id
     is (Nth_Item (Of_Tree, Id, Index));

   function Statement_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Run_Length (Of_Tree, Id));

   function Nth_Statement
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     is (Nth_Item (Of_Tree, Id, Index));

   function Callee_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Argument_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Run_Length (Of_Tree, Id));

   function Field_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Run_Length (Of_Tree, Id));

   function Nth_Field
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     is (Nth_Item (Of_Tree, Id, Index));

   function Nth_Argument
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     is (Nth_Item (Of_Tree, Id, Index));

   function Element_Count (Of_Tree : Tree; Id : Node_Id) return Natural
     is (Run_Length (Of_Tree, Id));

   function Nth_Element
     (Of_Tree : Tree; Id : Node_Id; Index : Positive) return Node_Id
     is (Nth_Item (Of_Tree, Id, Index));

   function Operand_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Left_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 1));

   function Right_Of (Of_Tree : Tree; Id : Node_Id) return Node_Id
     is (Slot (Of_Tree, Id, 2));

end Landin.Syntax;
