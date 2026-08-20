--  Target facts.
--
--  Nothing in the compiler may ask the host how wide a pointer is.  A
--  32-bit target is described here and measured by tests on a 64-bit
--  development machine, which is the only way the Cortex-M path can be
--  designed before a Cortex-M backend exists.
--
--  These are machine facts, not language facts.  There is deliberately no
--  list of Landin's scalar types here: which types exist, and how each one
--  maps onto a machine width, is the specification's business and arrives
--  with the frontend.  A description says what the machine can hold and
--  how it must be aligned, and nothing about what a program may name.
--
--  Target_Facts is private and has no defaults, so a description can only
--  come from one of the named constructors.  A record of defaults would
--  have described the development host, which is the one answer this
--  package exists to avoid.

package Landin.Targets is

   type Bit_Width is range 1 .. 1024;

   type Byte_Alignment is range 1 .. 4096;

   type Endianness is (Little, Big);

   --  The scalar sizes a backend has to lay out.  Sizes, not types: a
   --  four-byte scalar aligns the same way whether a program called it an
   --  integer, a float or a pointer.
   type Scalar_Size is (Byte_1, Byte_2, Byte_4, Byte_8, Byte_16);

   function Bytes (Size : Scalar_Size) return Positive
     is (case Size is
            when Byte_1  => 1,
            when Byte_2  => 2,
            when Byte_4  => 4,
            when Byte_8  => 8,
            when Byte_16 => 16);

   type Target_Facts is private;

   --  The first target the roadmap requires to execute.
   function Linux_X86_64 return Target_Facts;

   --  A synthetic 32-bit little-endian description, used to keep layout and
   --  ABI code target-parametric long before a real 32-bit backend exists.
   function Synthetic_32 return Target_Facts;

   function Name (Facts : Target_Facts) return String;

   function Pointer_Width (Facts : Target_Facts) return Bit_Width;

   function Pointer_Alignment (Facts : Target_Facts) return Byte_Alignment;

   function Stack_Alignment (Facts : Target_Facts) return Byte_Alignment;

   function Byte_Order (Facts : Target_Facts) return Endianness;

   --  Always true, and asked rather than assumed: `tour.txt` [1550] says
   --  the frame pointer is always set up, so a target that answered
   --  otherwise would be a target the roadmap has not agreed to.
   function Frame_Pointer (Facts : Target_Facts) return Boolean;

   --  The largest alignment this target gives any scalar.  A 64-bit scalar
   --  on a 32-bit machine is the case this exists for.
   function Max_Scalar_Alignment
     (Facts : Target_Facts) return Byte_Alignment;

   function Alignment_Of
     (Facts : Target_Facts; Size : Scalar_Size) return Byte_Alignment
     with Post => Alignment_Of'Result <= Max_Scalar_Alignment (Facts);

   function Pointer_Size (Facts : Target_Facts) return Scalar_Size;

   --  A count of target bytes.  Deliberately not Natural: the host Ada
   --  compiler's Integer width is a fact about the machine running the
   --  compiler, and a target offset must not inherit it.  The bound is one
   --  below a power of two so that rounding up near the top really can
   --  overflow, and is therefore a case a test can reach.
   type Byte_Count is range 0 .. 2 ** 48 - 1;

   --  Layout arithmetic that refuses to guess.  Alignment must be a power
   --  of two, and rounding up must not silently wrap.  Both rules are
   --  enforced in the body, in every build mode: a layout that only holds
   --  when assertions are on is not a layout.
   function Is_Power_Of_Two (Value : Byte_Alignment) return Boolean;

   function Align_Up
     (Offset : Byte_Count; Alignment : Byte_Alignment) return Byte_Count
     with Post => Align_Up'Result >= Offset
                  and then Align_Up'Result mod Byte_Count (Alignment) = 0;

private

   Name_Length : constant := 24;

   type Target_Facts is record
      Label             : String (1 .. Name_Length);
      Pointer           : Bit_Width;
      Pointer_Align     : Byte_Alignment;
      Stack_Align       : Byte_Alignment;
      Order             : Endianness;
      Keeps_Frame       : Boolean;
      Widest_Alignment  : Byte_Alignment;
   end record;

end Landin.Targets;
