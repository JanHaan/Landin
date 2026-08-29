--  The target-neutral exit vocabulary shared by semantic flow and lowering.
--
--  A cleanup is selected by the kind of edge leaving its lexical block.
--  `defer` applies to every language exit that unwinds a block; a trap is a
--  synchronous stop and never unwinds.  `undo` uses the same lexical stack
--  but is selected only while a declared failure propagates.

package Landin.Cleanup is

   type Exit_Kind is
     (Normal_Fallthrough,
      Successful_Return,
      Failure_Propagation,
      Structured_Transfer,
      Trap_Stop);

   type Cleanup_Kind is (Deferred_Call, Failure_Undo);

   function Applies
     (Cleanup : Cleanup_Kind; Edge : Exit_Kind) return Boolean
     is (case Cleanup is
            when Deferred_Call => Edge /= Trap_Stop,
            when Failure_Undo  => Edge = Failure_Propagation);

end Landin.Cleanup;
