--  What Clang's JSON AST says, read as the generator needs it: the
--  declarations a policy can select, each record's and enum's identity and
--  typedef names, and C types, from Clang's structural type nodes where it
--  gives them and from its type spellings where it does not.  Spellings are
--  Clang's printed forms, never header text.

private package Landin.Bindings.Clang is

   --  The member Key of Node, or J.No_Value.
   function Field (Within : Handle; Node : J.Value; Key : String)
     return J.Value;

   --  The string member Key of Node, or "" when it has none.
   function Text (Within : Handle; Node : J.Value; Key : String)
     return String;

   --  Whether the member Key of Node is present and what Python would
   --  call true: true, a nonempty string, a nonzero number, a nonempty
   --  array or object.
   function Truthy (Within : Handle; Node : J.Value; Key : String)
     return Boolean;

   function Has (Within : Handle; Node : J.Value; Key : String)
     return Boolean;

   --  Node's `inner` children, the AST's children of every node.
   function Inner (Within : Handle; Node : J.Value)
     return Value_Vectors.Vector;

   --  Read the declarations out of the AST already parsed into Within.Ast.
   procedure Build_Model (Within : Handle);

   --  The last declaration of a function, and of a variable the last
   --  `extern` one or else the last.
   function Function_Node (Within : Handle; Name : String) return J.Value;
   function Variable_Node (Within : Handle; Name : String) return J.Value;

   --  A record or enum by typedef, `struct`/`union`/`enum` tag, plain tag,
   --  or, for an anonymous enum, `@FIRST_CONSTANT`: its index, or zero.
   function Record_Of (Within : Handle; Selector : String) return Natural;
   function Enum_Of (Within : Handle; Selector : String) return Natural;

   function Record_Complete (Within : Handle; Index : Positive)
     return Boolean;
   function Record_Union (Within : Handle; Index : Positive) return Boolean;
   function Record_Packed (Within : Handle; Index : Positive)
     return Boolean;
   function Record_C_Name (Within : Handle; Index : Positive) return String;
   function Record_Display (Within : Handle; Index : Positive)
     return String;
   function Record_Fields (Within : Handle; Index : Positive)
     return Value_Vectors.Vector;
   function Enum_C_Name (Within : Handle; Index : Positive) return String;
   function Enum_Display (Within : Handle; Index : Positive) return String;
   function Enum_Constants (Within : Handle; Index : Positive)
     return Value_Vectors.Vector;

   function Record_Index (Within : Handle; Identity : String)
     return Positive;
   function Enum_Index (Within : Handle; Identity : String) return Positive;

   ---------------------------------------------------------------------
   --  Types
   ---------------------------------------------------------------------

   function Get (Within : Handle; Id : Type_Id) return C_Type
     with Pre => Id /= No_Type;

   function Make (Within : Handle; Item : C_Type) return Type_Id;

   --  The same type with Const as its qualifier.
   function With_Const
     (Within : Handle; Id : Type_Id; Const : Boolean)
      return Type_Id;

   --  A declaration's `type` member.
   function From_Info (Within : Handle; Info : J.Value)
     return Type_Id;

   --  A typedef by name, or by its declaration's identity when given.
   function Alias
     (Within : Handle; Name : String; Identity : String := "")
      return Type_Id;

   function Parse (Within : Handle; Spelling : String)
     return Type_Id;

   --  A function spelling's result and parameter text, as Clang prints a
   --  simple result followed by one complete parameter list; Found is
   --  false for anything else, `int (*(void))(int)` among them.
   procedure Split_Function
     (Text : String; Found : out Boolean;
      Result_Text, Parameter_Text : out US.Unbounded_String);

end Landin.Bindings.Clang;
