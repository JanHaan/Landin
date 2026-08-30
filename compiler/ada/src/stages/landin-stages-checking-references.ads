with Landin.Diagnostics;
with Landin.Syntax;

private package Landin.Stages.Checking.References is

   --  [0770]--[0860]: the deliberately local reference-origin pass.  Type
   --  checking has already retained complete reference and signature
   --  descriptors; this pass carries only body-local derivation facts and
   --  reports escape, declared-return-source and live-borrow violations.
   procedure Check_Function
     (Context       : in out Compilation;
      Of_Tree       : Landin.Syntax.Tree;
      Function_Node : Landin.Syntax.Node_Id;
      Body_Node     : Landin.Syntax.Node_Id;
      Into          : in out Landin.Diagnostics.Diagnostic_List);

end Landin.Stages.Checking.References;
