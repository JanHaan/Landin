with Landin.Optimization;

package Landin.IR.Specialization_Policy is
   --  Scores are IR policy estimates, not assembled bytes. Caps are applied
   --  before arithmetic, independent of source size and host word width.
   function Benefit (Entries, Loop_Depth, Size_Term : Natural) return Natural;
   function Profitable
     (Score, Growth : Natural;
      Objective : Landin.Optimization.Objective) return Boolean;
end Landin.IR.Specialization_Policy;
