with Landin.Diagnostics;
with Landin.Syntax;

private package Landin.Stages.Checking.Flow is

   procedure Check_Function
     (Context       : in out Compilation;
      Of_Tree       : Landin.Syntax.Tree;
      Function_Node : Landin.Syntax.Node_Id;
      Body_Node     : Landin.Syntax.Node_Id;
      Result_Node   : Landin.Syntax.Node_Id;
      Into          : in out Landin.Diagnostics.Diagnostic_List);

end Landin.Stages.Checking.Flow;
