--  Format-independent variable availability at neutral instruction boundaries.
--  A physical home is not evidence of initialization.  Meet predecessor
--  states before describing a local, including joins and loop backedges.
with Ada.Containers.Vectors;
with Landin.Debugging;
with Landin.Resolution;

package Landin.Backend.Debug_Locations is

   package Flags is new Ada.Containers.Vectors (Positive, Boolean);

   function Within
     (Meanings : Landin.Resolution.Table;
      Inner, Outer : Landin.Resolution.Scope_Id) return Boolean;

   function Available
     (Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Landin.IR.Item_Id;
      Slot : Landin.IR.Slot_Id;
      Parameter : Boolean) return Flags.Vector;

   function Available_Alias
     (Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Landin.IR.Item_Id;
      Index : Positive) return Flags.Vector;

end Landin.Backend.Debug_Locations;
