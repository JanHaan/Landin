--  D227: memory operations and ordering legality, independent of targets.
--
--  D450's two stack builtins take the same path as the atomics: each is a
--  `compiler` member called as an ordinary call, its arguments evaluated
--  once from left to right, and a full compiler memory boundary.  In the
--  IR, Stack_Prepare's slice is its base and its length, so it carries four
--  usize operands (base, length, entry, argument) and gives the usize stack
--  pointer a later switch resumes; Stack_Switch carries two (the address
--  it saves through and the stack pointer it resumes) and gives nothing.
--  The limit a switch once took is in the frames it saves (D472).

package Landin.Memory is
   type Operation is
     (No_Operation, Atomic_Load, Atomic_Store, Atomic_Exchange, Atomic_Add,
      Atomic_Compare_Exchange, Volatile_Load, Volatile_Store,
      Compiler_Barrier, Thread_Fence, Device_Barrier, Completion_Barrier,
      Stack_Prepare, Stack_Switch);
   subtype Stack_Operation is Operation range Stack_Prepare .. Stack_Switch;
   type Ordering is (No_Ordering, Relaxed, Acquire, Release, Acq_Rel, Seq_Cst);

   function Named (Name : String) return Operation;
   function Order_Named (Name : String) return Ordering;
   --  The IR operands.  Source_Arguments is how many value arguments the
   --  call is written with, before any ordering or contract arguments.
   function Operands (Op : Operation) return Natural;
   function Source_Arguments (Op : Operation) return Natural;
   function Orders (Op : Operation) return Natural;
   function Returns_Value (Op : Operation) return Boolean
     is (Op in Atomic_Load | Atomic_Exchange | Atomic_Add
           | Atomic_Compare_Exchange | Volatile_Load | Stack_Prepare);
   function Writes (Op : Operation) return Boolean
     is (Op in Atomic_Store | Atomic_Exchange | Atomic_Add
           | Atomic_Compare_Exchange | Volatile_Store | Stack_Operation);
   function Legal
     (Op : Operation; Success, Failure : Ordering) return Boolean;
   --  The two halves of an ordering, which each backend's mapping reads
   --  (D499): an acquiring read keeps later accesses after it, a releasing
   --  write keeps earlier ones before it.  Acq_rel and seq_cst do both.
   function Acquires (Order : Ordering) return Boolean
     is (Order in Acquire | Acq_Rel | Seq_Cst);
   function Releases (Order : Ordering) return Boolean
     is (Order in Release | Acq_Rel | Seq_Cst);
end Landin.Memory;
