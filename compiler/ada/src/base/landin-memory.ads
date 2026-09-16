--  D227: memory operations and ordering legality, independent of targets.

package Landin.Memory is
   type Operation is
     (No_Operation, Atomic_Load, Atomic_Store, Atomic_Exchange, Atomic_Add,
      Atomic_Compare_Exchange, Volatile_Load, Volatile_Store,
      Compiler_Barrier, Thread_Fence, Device_Barrier, Completion_Barrier);
   type Ordering is (No_Ordering, Relaxed, Acquire, Release, Acq_Rel, Seq_Cst);

   function Named (Name : String) return Operation;
   function Order_Named (Name : String) return Ordering;
   function Operands (Op : Operation) return Natural;
   function Orders (Op : Operation) return Natural;
   function Returns_Value (Op : Operation) return Boolean
     is (Op in Atomic_Load | Atomic_Exchange | Atomic_Add
           | Atomic_Compare_Exchange | Volatile_Load);
   function Writes (Op : Operation) return Boolean
     is (Op in Atomic_Store | Atomic_Exchange | Atomic_Add
           | Atomic_Compare_Exchange | Volatile_Store);
   function Legal
     (Op : Operation; Success, Failure : Ordering) return Boolean;
end Landin.Memory;
