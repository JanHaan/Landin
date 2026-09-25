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
