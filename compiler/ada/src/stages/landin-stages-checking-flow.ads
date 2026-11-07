--  The body-local definite-assignment, sink and cleanup pass. Types and
--  resolved places are already available when it enforces assignment before
--  reading [1910] and consumption/reassignment [0910], meeting facts only on
--  edges that reach a join. Deferred and undo actions participate on their
--  own exit edges, rather than acting as ordinary fallthrough statements.
--
--  Facts track declarations and their fields and array elements. Widest
--  bounds the field dimension once for the compilation before a routine's
--  facts are created. Reference origins and escape belong to References;
--  this pass does not infer storage lifetimes or choose expression types.

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
