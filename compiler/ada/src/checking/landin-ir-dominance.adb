with Ada.Unchecked_Deallocation;

package body Landin.IR.Dominance is

   procedure Free is new Ada.Unchecked_Deallocation
     (Object => Block_Array, Name => Block_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Object => Index_Array, Name => Index_Array_Access);

   --  Build's scratch, released however Build ends.
   type Scratch is new Ada.Finalization.Limited_Controlled with record
      Data : Index_Array_Access;
   end record;
   overriding procedure Finalize (Value : in out Scratch);

   overriding procedure Finalize (Value : in out Scratch) is
   begin
      Free (Value.Data);
   end Finalize;

   function Create (Count : Natural) return Scratch;
   function Create (Count : Natural) return Scratch is
   begin
      return Result : Scratch do
         Result.Data := new Index_Array'(1 .. Count => 0);
      end return;
   end Create;

   overriding procedure Finalize (Value : in out Tree) is
   begin
      Free (Value.Idom);
      Free (Value.Order);
      Free (Value.Pre);
      Free (Value.Last);
   end Finalize;

   procedure Build (Into : in out Tree; Of_Graph : Control_Flow.Graph) is
      Count : constant Natural := Of_Graph.Count;
      Number_Owner : constant Scratch := Create (Count);
      Vertex_Owner : constant Scratch := Create (Count);
      Parent_Owner : constant Scratch := Create (Count);
      Semi_Owner : constant Scratch := Create (Count);
      Ancestor_Owner : constant Scratch := Create (Count);
      Best_Owner : constant Scratch := Create (Count);
      Same_Owner : constant Scratch := Create (Count);
      Bucket_Owner : constant Scratch := Create (Count);
      Next_Owner : constant Scratch := Create (Count);
      Path_Owner : constant Scratch := Create (Count);
      --  Preorder number of the depth-first walk, and its inverse.
      Number : Index_Array renames Number_Owner.Data.all;
      Vertex : Index_Array renames Vertex_Owner.Data.all;
      Parent : Index_Array renames Parent_Owner.Data.all;
      Semi : Index_Array renames Semi_Owner.Data.all;
      Ancestor : Index_Array renames Ancestor_Owner.Data.all;
      Best : Index_Array renames Best_Owner.Data.all;
      Same : Index_Array renames Same_Owner.Data.all;
      --  Each block waits in at most one bucket, so the buckets are lists
      --  threaded through one array.  The walk's successor cursor reuses
      --  the same storage before any bucket exists.
      Bucket : Index_Array renames Bucket_Owner.Data.all;
      Next : Index_Array renames Next_Owner.Data.all;
      Path : Index_Array renames Path_Owner.Data.all;
      Reached_Count : Natural := 0;

      --  The ancestor in the linked forest whose semidominator is least,
      --  compressing the path it walks.  Iterative: a path may be as long
      --  as the routine.
      function Evaluate (Block : Positive) return Positive;
      function Evaluate (Block : Positive) return Positive is
         At_Block : Positive := Block;
         Depth : Natural := 0;
      begin
         while Ancestor (Ancestor (At_Block)) /= 0 loop
            Depth := Depth + 1;
            Path (Depth) := At_Block;
            At_Block := Ancestor (At_Block);
         end loop;
         Into.Steps := Into.Steps + Depth + 1;
         for Index in reverse 1 .. Depth loop
            declare
               Step : constant Positive := Path (Index);
               Up : constant Positive := Ancestor (Step);
               Candidate : constant Positive := Best (Up);
            begin
               Ancestor (Step) := Ancestor (Up);
               if Number (Semi (Candidate)) < Number (Semi (Best (Step)))
               then
                  Best (Step) := Candidate;
               end if;
            end;
         end loop;
         return Best (Block);
      end Evaluate;
   begin
      Finalize (Into);
      Into.Count := Count;
      Into.Steps := 0;
      Into.Idom := new Block_Array'(1 .. Count => No_Block);
      Into.Order := new Block_Array'(1 .. Count => No_Block);
      Into.Pre := new Index_Array'(1 .. Count => 0);
      Into.Last := new Index_Array'(1 .. Count => 0);
      Into.Reached_Count := 0;
      if Count = 0 then
         return;
      end if;
      --  Depth-first numbering from the entry, with an explicit stack;
      --  Next holds each block's next successor to try.
      declare
         Stack : Index_Array renames Path;
         Depth : Natural := 1;
      begin
         Reached_Count := 1;
         Number (1) := 1;
         Vertex (1) := 1;
         Stack (1) := 1;
         Next (1) := 1;
         while Depth > 0 loop
            declare
               Top : constant Positive := Stack (Depth);
            begin
               if Next (Top) > 2 then
                  Depth := Depth - 1;
               else
                  declare
                     Target : constant Block_Id := Control_Flow.Successor
                       (Of_Graph, Block_Id (Top), Next (Top));
                  begin
                     Next (Top) := Next (Top) + 1;
                     if Target /= No_Block
                       and then Number (Positive (Target)) = 0
                     then
                        Reached_Count := Reached_Count + 1;
                        Number (Positive (Target)) := Reached_Count;
                        Vertex (Reached_Count) := Positive (Target);
                        Parent (Positive (Target)) := Top;
                        Next (Positive (Target)) := 1;
                        Depth := Depth + 1;
                        Stack (Depth) := Positive (Target);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
      for Index in Next'Range loop
         Next (Index) := 0;
      end loop;
      --  Semidominators in reverse walk order, each block's immediate
      --  dominator settled or deferred to a block with the same one.
      for Index in reverse 2 .. Reached_Count loop
         declare
            Block : constant Positive := Vertex (Index);
            Up : constant Positive := Parent (Block);
            Semidominator : Positive := Up;
            Edge : Natural := Control_Flow.First_Predecessor
              (Of_Graph, Block_Id (Block));
            Waiting : Natural;
         begin
            while Edge /= 0 loop
               declare
                  From : constant Positive := Positive
                    (Control_Flow.Predecessor (Of_Graph, Edge));
                  Candidate : Positive;
               begin
                  if Number (From) /= 0 then
                     Candidate :=
                       (if Number (From) <= Number (Block) then From
                        else Semi (Evaluate (From)));
                     if Number (Candidate) < Number (Semidominator) then
                        Semidominator := Candidate;
                     end if;
                  end if;
               end;
               Edge := Control_Flow.Next_Predecessor (Of_Graph, Edge);
            end loop;
            Semi (Block) := Semidominator;
            Next (Block) := Bucket (Semidominator);
            Bucket (Semidominator) := Block;
            Ancestor (Block) := Up;
            Best (Block) := Block;
            Waiting := Bucket (Up);
            while Waiting /= 0 loop
               declare
                  Lowest : constant Positive := Evaluate (Waiting);
               begin
                  if Semi (Lowest) = Semi (Waiting) then
                     Into.Idom (Waiting) := Block_Id (Up);
                  else
                     Same (Waiting) := Lowest;
                  end if;
               end;
               Waiting := Next (Waiting);
            end loop;
            Bucket (Up) := 0;
         end;
      end loop;
      for Index in 2 .. Reached_Count loop
         declare
            Block : constant Positive := Vertex (Index);
         begin
            if Same (Block) /= 0 then
               Into.Idom (Block) := Into.Idom (Same (Block));
            end if;
         end;
      end loop;
      --  The tree's preorder: children threaded through Bucket and Next,
      --  then a stack walk that finishes each subtree before the next.
      for Index in 1 .. Count loop
         Bucket (Index) := 0;
      end loop;
      for Index in reverse 2 .. Reached_Count loop
         declare
            Block : constant Positive := Vertex (Index);
            Up : constant Positive := Positive (Into.Idom (Block));
         begin
            Next (Block) := Bucket (Up);
            Bucket (Up) := Block;
         end;
      end loop;
      declare
         Stack : Index_Array renames Path;
         Depth : Natural := 1;
         Placed : Natural := 0;
         Size : Index_Array renames Semi;
      begin
         Stack (1) := 1;
         while Depth > 0 loop
            declare
               Block : constant Positive := Stack (Depth);
               Child : Natural := Bucket (Block);
            begin
               Depth := Depth - 1;
               Placed := Placed + 1;
               Into.Pre (Block) := Placed;
               Into.Order (Placed) := Block_Id (Block);
               while Child /= 0 loop
                  Depth := Depth + 1;
                  Stack (Depth) := Child;
                  Child := Next (Child);
               end loop;
            end;
         end loop;
         --  Every child follows its parent in preorder, so a reverse walk
         --  sees a subtree whole before its root.
         for Index in 1 .. Count loop
            Size (Index) := 1;
         end loop;
         for Index in reverse 2 .. Placed loop
            declare
               Block : constant Positive := Positive (Into.Order (Index));
               Up : constant Positive := Positive (Into.Idom (Block));
            begin
               Size (Up) := Size (Up) + Size (Block);
            end;
         end loop;
         for Index in 1 .. Placed loop
            declare
               Block : constant Positive := Positive (Into.Order (Index));
            begin
               Into.Last (Block) := Index + Size (Block) - 1;
            end;
         end loop;
      end;
      Into.Reached_Count := Reached_Count;
   end Build;

   function Immediate (Of_Tree : Tree; Block : Block_Id) return Block_Id
     is (Of_Tree.Idom (Positive (Block)));

   function Position (Of_Tree : Tree; Block : Block_Id) return Natural
     is (Of_Tree.Pre (Positive (Block)));

   function Last_Below (Of_Tree : Tree; Block : Block_Id) return Natural
     is (Of_Tree.Last (Positive (Block)));

   function Reached (Of_Tree : Tree) return Natural
     is (Of_Tree.Reached_Count);

   function Block_At (Of_Tree : Tree; Index : Positive) return Block_Id
     is (Of_Tree.Order (Index));

   function Dominates (Of_Tree : Tree; Upper, Lower : Block_Id)
     return Boolean
     is (Of_Tree.Pre (Positive (Upper)) /= 0
         and then Of_Tree.Pre (Positive (Lower)) /= 0
         and then Of_Tree.Pre (Positive (Upper))
           <= Of_Tree.Pre (Positive (Lower))
         and then Of_Tree.Pre (Positive (Lower))
           <= Of_Tree.Last (Positive (Upper)));

   function Strictly_Dominates (Of_Tree : Tree; Upper, Lower : Block_Id)
     return Boolean
     is (Upper /= Lower and then Dominates (Of_Tree, Upper, Lower));

   function Evaluation_Steps (Of_Tree : Tree) return Natural
     is (Of_Tree.Steps);
end Landin.IR.Dominance;
