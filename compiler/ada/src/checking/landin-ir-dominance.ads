with Ada.Finalization;
with Landin.IR.Control_Flow;

--  The dominator tree of one routine's blocks, by Lengauer and Tarjan's
--  algorithm with path compression: O(E log V) for V blocks and E edges,
--  and linear space.  Block A dominates block B when every path from the
--  entry to B passes A.  A block the entry does not reach has no place in
--  the tree and dominates, and is dominated by, nothing.
package Landin.IR.Dominance is

   type Tree is limited private;

   procedure Build (Into : in out Tree; Of_Graph : Control_Flow.Graph);

   --  The block's immediate dominator; No_Block for the entry and for a
   --  block the entry does not reach.
   function Immediate (Of_Tree : Tree; Block : Block_Id) return Block_Id;

   --  Positions in a preorder walk of the tree, from one.  A block's
   --  subtree is the run from its own position to Last_Below's, so a
   --  dominance question is two comparisons.  Zero for an unreached block.
   function Position (Of_Tree : Tree; Block : Block_Id) return Natural;
   function Last_Below (Of_Tree : Tree; Block : Block_Id) return Natural;
   function Reached (Of_Tree : Tree) return Natural;
   function Block_At (Of_Tree : Tree; Index : Positive) return Block_Id;

   function Dominates (Of_Tree : Tree; Upper, Lower : Block_Id)
     return Boolean;
   function Strictly_Dominates (Of_Tree : Tree; Upper, Lower : Block_Id)
     return Boolean;

   --  Exact work counter for deterministic scale tests, not elapsed time:
   --  every step the compressing evaluation takes, which the path
   --  compression bounds by O(E log V).
   function Evaluation_Steps (Of_Tree : Tree) return Natural;

private
   type Block_Array is array (Positive range <>) of Block_Id;
   type Block_Array_Access is access Block_Array;
   type Index_Array is array (Positive range <>) of Natural;
   type Index_Array_Access is access Index_Array;

   type Tree is new Ada.Finalization.Limited_Controlled with record
      Count : Natural := 0;
      Idom : Block_Array_Access;
      Order : Block_Array_Access;
      Pre, Last : Index_Array_Access;
      Reached_Count : Natural := 0;
      Steps : Natural := 0;
   end record;

   overriding procedure Finalize (Value : in out Tree);
end Landin.IR.Dominance;
