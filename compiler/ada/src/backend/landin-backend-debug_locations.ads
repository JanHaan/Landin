--  Format-independent variable availability at neutral instruction boundaries.
--  A physical home is not evidence of initialization.  Meet predecessor
--  states before describing a local, including joins and loop backedges.
--  Return/failure entries retain those facts; a machine consumer must end
--  their ranges before restoring registers or dismantling the frame.
with Ada.Containers.Vectors;
with Landin.Debugging;
with Landin.IR.Control_Flow;
with Landin.Resolution;

package Landin.Backend.Debug_Locations is

   package Flags is new Ada.Containers.Vectors (Positive, Boolean);

   --  Reuse a routine's graph and block-entry states across its variables
   --  and aliases.  The latter can have different bindings and leaf paths,
   --  but the fixed point is identical for the same slot, entry state and
   --  birth instruction.
   type Analysis (Blocks, Slots : Natural) is private;

   function Prepare
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return Analysis;

   function Fixed_Point_Count (Work : Analysis) return Natural;

   function Within
     (Meanings : Landin.Resolution.Table;
      Inner, Outer : Landin.Resolution.Scope_Id) return Boolean;

   function Available
     (Work : in out Analysis;
      Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Landin.IR.Item_Id;
      Slot : Landin.IR.Slot_Id;
      Parameter : Boolean) return Flags.Vector;

   function Available
     (Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Landin.IR.Item_Id;
      Slot : Landin.IR.Slot_Id;
      Parameter : Boolean) return Flags.Vector;

   function Available_Alias
     (Work : in out Analysis;
      Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Landin.IR.Item_Id;
      Index : Positive) return Flags.Vector;

   function Available_Alias
     (Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Landin.IR.Item_Id;
      Index : Positive) return Flags.Vector;

private
   type Interval is record
      First, Last : Landin.IR.Element_Total := 0;
   end record;
   package Intervals is new Ada.Containers.Vectors (Positive, Interval);
   package Block_States is new Ada.Containers.Vectors
     (Positive, Intervals.Vector, Intervals."=");

   type Cache_Item is record
      Ready : Boolean := False;
      Inputs : Block_States.Vector;
   end record;
   type Slot_Cache is array (1 .. 3) of Cache_Item;
   type Entries is array (Positive range <>) of Slot_Cache;
   type Slot_Flags is array (Positive range <>) of Boolean;

   type Analysis (Blocks, Slots : Natural) is record
      Graph : Landin.IR.Control_Flow.Graph (Blocks);
      Cache : Entries (1 .. Slots);
      Reuse : Slot_Flags (1 .. Slots);
      Solves : Natural := 0;
   end record;
end Landin.Backend.Debug_Locations;
