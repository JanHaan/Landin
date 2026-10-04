--  Test-only access to the verifier's instance-owned allocation probe and
--  checked byte arithmetic. This child is absent from the production GPR.

package Landin.IR.Verifier.Testing_Support is
   type Observation is record
      Found : Fault := Sound;
      Exhausted : Boolean := False;
      Reached, Allocations, Releases, Live : Natural := 0;
      Live_Bytes, Peak_Bytes : System.Storage_Elements.Storage_Count := 0;
   end record;

   function Observe
     (Of_Unit : Unit; Facts : Landin.Targets.Target_Facts;
      Fail_At : Natural := 0) return Observation;

   function Scratch_Bytes
     (Count : Natural; Width : System.Storage_Elements.Storage_Count)
      return System.Storage_Elements.Storage_Count;
end Landin.IR.Verifier.Testing_Support;
