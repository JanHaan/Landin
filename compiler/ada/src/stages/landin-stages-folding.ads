--  One constant folder for both stages that need one.
--
--  The checker asks what a module value or a fixed bound is before it
--  decides a rule; lowering asks the same question again to form a static
--  image.  Until R4.21 each had its own seven-hundred-line copy, already
--  diverged, and lowering raised a defect wherever its copy knew less than
--  the checker's.  This generic is the one walk.  A stage instantiates it
--  with its tables and the few questions only that stage can answer: how
--  a name reaches its tree, which scalar a call-shaped conversion targets,
--  what a character literal is worth, whether a member selection names a
--  float special, and what to do when a module value is worked out from
--  itself, which the checker reports and lowering merely declines.
--
--  Values are Landin.Types.Folded.  An integer or bool node folds to its
--  value; a float-typed node folds to the bit pattern of its IEEE value,
--  which is what a static image stores and what the checker compares.
--  Overflowed is a distinct outcome from "not known": an operand nobody
--  can fold arrives with both False, an arithmetic result that does not
--  fit, or a conversion that does not, arrives with Overflowed True.

with Landin.Checking;
with Landin.Resolution;
with Landin.Source;
with Landin.Syntax;
with Landin.Targets;
with Landin.Types;

private generic
   Types    : not null access Landin.Checking.Table;
   Meanings : not null access Landin.Resolution.Table;
   Facts    : Landin.Targets.Target_Facts;

   with function Snapshot_Of
     (Source : Landin.Source.Source_Id) return Landin.Source.Snapshot;
   with function Tree_For
     (Source : Landin.Source.Source_Id)
      return not null access constant Landin.Syntax.Tree;

   --  The scalar a call-shaped conversion `t(x)` targets, or a kind
   --  outside Scalar_Name when the call is not one.
   with function Conversion_Target
     (Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Landin.Types.Type_Kind;
   with function Character_Value
     (Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Landin.Types.Magnitude;

   --  For a member selection that names `f32.infinity` or `f64.nan`, the
   --  float kind and the pattern; any other kind says it is not one.
   with function Float_Special_Type
     (Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Landin.Types.Type_Kind;
   with function Float_Special_Bits
     (Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Landin.Types.Magnitude;

   --  Entering a module binding's initializer through its name.  False
   --  says the binding is already being folded, so the chain came back
   --  to where it began: the stage has said what it wants to about that.
   with function Enter (Means : Landin.Resolution.Declaration_Id)
     return Boolean;
   with procedure Leave (Means : Landin.Resolution.Declaration_Id);
package Landin.Stages.Folding is

   procedure Fold
     (Of_Tree    : Landin.Syntax.Tree;
      Node       : Landin.Syntax.Node_Id;
      Depth      : Natural;
      Value      : out Landin.Types.Folded;
      Known      : out Boolean;
      Overflowed : out Boolean);

end Landin.Stages.Folding;
