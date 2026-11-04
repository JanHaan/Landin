--  The build report's static site counts for a backend whose final text is
--  its record of what it selected: every instruction line of one routine's
--  text, those of them that load or store through the stack, and its direct
--  and indirect calls.  x86-64 counts the same things from its selected
--  instruction stream (Landin.Backend.X86_64.Machine).
--
--  A load or store reaches the stack when its address is the stack pointer,
--  the frame pointer, or a register the routine set from one of them by a
--  move or an addition since the last label or call.  Arm64, RISC-V and
--  Thumb reach a cell beyond their short displacements through such a
--  register, so a count of the first two alone would miss most of the frame
--  traffic of a large frame.  A push is a store and a pop a load.  A call
--  that saves its return address in a register is no stack traffic; one
--  that pushes it, as x86-64's does, is.  Labels and directives are not
--  instructions.  Nothing here selects, rewrites or assembles.
with Landin.Build_Reports;

package Landin.Backend.Site_Counts is

   type Syntax is (A64, RISC_V, Thumb, Xtensa);

   type Counter (Of_Syntax : Syntax) is private;

   --  One line of the routine's final text, without its line feed.
   procedure Add (Into : in out Counter; Line : String);

   --  Each line of Text, ended by a line feed or by Text's end.
   procedure Add_Lines (Into : in out Counter; Text : String);

   --  Instructions, Stack_Loads, Stack_Stores, Direct_Calls and
   --  Indirect_Calls from what was added; the other fields are left alone.
   procedure Fill
     (From : Counter;
      Into : in out Landin.Build_Reports.Routine_Statistics);

   --  Nothing counted, for the next routine.
   procedure Clear (Into : in out Counter);

private

   type Register_Set is array (0 .. 31) of Boolean;

   type Counter (Of_Syntax : Syntax) is record
      --  Registers holding an address in the frame, other than the stack
      --  and frame pointers themselves, which always do.
      Derived : Register_Set := [others => False];
      Instructions : Natural := 0;
      Loads : Natural := 0;
      Stores : Natural := 0;
      Direct : Natural := 0;
      Indirect : Natural := 0;
   end record;

end Landin.Backend.Site_Counts;
