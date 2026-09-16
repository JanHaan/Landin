package body Landin.Memory is
   function Named (Name : String) return Operation is
   begin
      for Op in Operation range Atomic_Load .. Completion_Barrier loop
         declare
            Upper : constant String := Operation'Image (Op);
            Equal : Boolean := Name'Length = Upper'Length;
         begin
            if Equal then
               for I in Upper'Range loop
                  if Name (Name'First + I - Upper'First) /=
                    (if Upper (I) in 'A' .. 'Z'
                     then Character'Val (Character'Pos (Upper (I)) + 32)
                     else Upper (I))
                  then
                     Equal := False;
                  end if;
               end loop;
            end if;
            if Equal then
               return Op;
            end if;
         end;
      end loop;
      return No_Operation;
   end Named;

   function Order_Named (Name : String) return Ordering is
   begin
      if Name = "relaxed" then
         return Relaxed;
      elsif Name = "acquire" then
         return Acquire;
      elsif Name = "release" then
         return Release;
      elsif Name = "acq_rel" then
         return Acq_Rel;
      elsif Name = "seq_cst" then
         return Seq_Cst;
      else
         return No_Ordering;
      end if;
   end Order_Named;

   function Operands (Op : Operation) return Natural is
     (case Op is
         when Atomic_Load | Volatile_Load => 1,
         when Atomic_Store | Atomic_Exchange | Atomic_Add
            | Volatile_Store => 2,
         when Atomic_Compare_Exchange => 3,
         when others => 0);

   function Orders (Op : Operation) return Natural is
     (case Op is
         when Atomic_Compare_Exchange => 2,
         when Atomic_Load .. Atomic_Add | Thread_Fence => 1,
         when others => 0);

   function Legal
     (Op : Operation; Success, Failure : Ordering) return Boolean is
   begin
      if Op = No_Operation then
         return False;
      elsif Orders (Op) = 0 then
         return Success = No_Ordering and then Failure = No_Ordering;
      elsif Success = No_Ordering then
         return False;
      elsif Op = Atomic_Compare_Exchange then
         return Failure = Relaxed
           or else (Failure = Acquire and then
                     Success in Acquire | Acq_Rel | Seq_Cst)
           or else (Failure = Seq_Cst and then Success = Seq_Cst);
      elsif Failure /= No_Ordering then
         return False;
      elsif Op = Atomic_Load then
         return Success in Relaxed | Acquire | Seq_Cst;
      elsif Op = Atomic_Store then
         return Success in Relaxed | Release | Seq_Cst;
      elsif Op = Thread_Fence then
         return Success in Acquire | Release | Acq_Rel | Seq_Cst;
      else
         return True;
      end if;
   end Legal;
end Landin.Memory;
