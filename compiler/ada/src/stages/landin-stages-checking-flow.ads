--  [1910] and [0910]: the body-local pass for definite assignment, sinks
--  and cleanup.  Type checking has already typed the body and resolution
--  has named its places.  A place must be assigned on every path before it
--  is read, and a place a `sink` consumed stays dead until it is assigned
--  again; where paths meet, only the edges that reach the join contribute
--  facts.  A deferred or undo call runs on the exit edges it applies to,
--  not as a statement the body falls through.
--
--  A fact names a declaration or one of its fields or array elements.
--  Widest_Struct bounds the field identities once per compilation, before
--  any function's facts exist.  Reference origins and escape belong to
--  References; this pass neither infers storage lifetimes nor chooses
--  expression types.

with Landin.Diagnostics;
with Landin.Syntax;

private package Landin.Stages.Checking.Flow is

   procedure Check_Function
     (Context       : in out Compilation;
      Of_Tree       : Landin.Syntax.Tree;
      Function_Node : Landin.Syntax.Node_Id;
      Body_Node     : Landin.Syntax.Node_Id;
      Result_Node   : Landin.Syntax.Node_Id;
      Widest        : Natural;
      Into          : in out Landin.Diagnostics.Diagnostic_List);

   --  The widest struct the program writes, which bounds the field
   --  identities a fact can name.  The forest is fixed once checking
   --  begins, so a caller works this out once and passes it to every
   --  function it checks.
   function Widest_Struct (Context : in out Compilation) return Natural;

end Landin.Stages.Checking.Flow;
