--  A binding policy, read from JSON (`bindings/README.md`): its schema,
--  namespace and ABI, and each selected declaration with what its kind
--  requires.  A member the policy does not know, one missing and a key
--  given twice are all refused, the last before anything else is read.

private package Landin.Bindings.Policies is

   --  Read Text into Within's policy, or Fail with a Policy_Fault.
   procedure Load (Within : Handle; Text : String);

   --  The member Key of Item in the policy, or J.No_Value.
   function Field (Within : Handle; Item : J.Value; Key : String)
     return J.Value;

   function Has (Within : Handle; Item : J.Value; Key : String)
     return Boolean;

   --  The string member Key of Item, or "" when it is not one.
   function Text (Within : Handle; Item : J.Value; Key : String)
     return String;

   --  Whether the member Key of Item is JSON true.
   function Is_True (Within : Handle; Item : J.Value; Key : String)
     return Boolean;

   --  The names of an object's members, in the order written; none when
   --  Item is not an object.
   function Keys (Within : Handle; Item : J.Value)
     return String_Vectors.Vector;

   --  The elements of an array member, or none.
   function Elements (Within : Handle; Item : J.Value)
     return Value_Vectors.Vector;

   --  A reference position's policy, or Fail naming Context.
   function Annotation_Of
     (Within : Handle; Item : J.Value; Context : String)
      return Annotation;

   function Repr (Within : Handle; Item : J.Value) return String;

   function Context (Of_Entry : Policy_Entry) return String;

   function Kind_Name (Kind : Entry_Kind) return String;

end Landin.Bindings.Policies;
