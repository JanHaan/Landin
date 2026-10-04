package body Landin.IR.Verifier.Testing_Support is
   function Observe
     (Of_Unit : Unit; Facts : Landin.Targets.Target_Facts;
      Fail_At : Natural := 0) return Observation
   is
      Probe : aliased Scratch_Probe := (Fail_At => Fail_At, others => <>);
      Result : Observation;
   begin
      begin
         Result.Found := Check_With_Probe (Of_Unit, Facts, Probe'Access);
      exception
         when Storage_Error =>
            Result.Exhausted := True;
      end;
      Result.Reached := Probe.Reached;
      Result.Allocations := Probe.Allocations;
      Result.Releases := Probe.Releases;
      Result.Live := Probe.Live;
      Result.Live_Bytes := Probe.Live_Bytes;
      Result.Peak_Bytes := Probe.Peak_Bytes;
      return Result;
   end Observe;

   function Scratch_Bytes
     (Count : Natural; Width : System.Storage_Elements.Storage_Count)
      return System.Storage_Elements.Storage_Count
     is (Checked_Scratch_Bytes (Count, Width));
end Landin.IR.Verifier.Testing_Support;
