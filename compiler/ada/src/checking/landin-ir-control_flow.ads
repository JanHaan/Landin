--  Linear-space adjacency and entry reachability for structurally checked
--  IR.  Storage counts source blocks and edges, never represented bytes.
package Landin.IR.Control_Flow is

   type Graph (Count : Natural) is private;

   --  The caller has checked block runs, terminators and target identities.
   --  Reachability itself is deliberately not a precondition.
   function Make (Of_Unit : Unit; Item : Item_Id) return Graph;

   function Is_Reachable (Of_Graph : Graph; Block : Block_Id) return Boolean;
   function Successor
     (Of_Graph : Graph; Block : Block_Id; Index : Positive) return Block_Id;
   function First_Predecessor
     (Of_Graph : Graph; Block : Block_Id) return Natural;
   function Next_Predecessor
     (Of_Graph : Graph; Edge : Positive) return Natural;
   function Predecessor
     (Of_Graph : Graph; Edge : Positive) return Block_Id;

   --  Exact work counters for deterministic scale tests, not elapsed time.
   function Node_Visits (Of_Graph : Graph) return Natural;
   function Edge_Visits (Of_Graph : Graph) return Natural;

private
   type Block_Array is array (Positive range <>) of Block_Id;
   type Index_Array is array (Positive range <>) of Natural;
   type Live_Array is array (Positive range <>) of Boolean;
   type Edge_Record is record
      Source : Block_Id := No_Block;
      Next   : Natural := 0;
   end record;
   type Edge_Pair is array (1 .. 2) of Edge_Record;
   type Edge_Array is array (Positive range <>) of Edge_Pair;
   type Graph (Count : Natural) is record
      First, Second : Block_Array (1 .. Count) := [others => No_Block];
      Incoming : Index_Array (1 .. Count) := [others => 0];
      Edges : Edge_Array (1 .. Count) :=
        [others => [others => (others => <>)]];
      Live : Live_Array (1 .. Count) := [others => False];
      Nodes_Visited, Edges_Visited : Natural := 0;
   end record;
end Landin.IR.Control_Flow;
