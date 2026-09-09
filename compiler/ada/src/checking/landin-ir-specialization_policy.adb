package body Landin.IR.Specialization_Policy is
   function Benefit (Entries, Loop_Depth, Size_Term : Natural) return Natural
     is (8 * Natural'Min (Entries, 32)
         * (1 + Natural'Min (Loop_Depth, 4)) + Natural'Min (Size_Term, 16));

   function Profitable
     (Score, Growth : Natural;
      Objective : Landin.Optimization.Objective) return Boolean
     is (case Objective is
            when Landin.Optimization.Speed => Score >= Growth,
            when Landin.Optimization.None | Landin.Optimization.Size =>
               Score / 4 >= Growth);
end Landin.IR.Specialization_Policy;
