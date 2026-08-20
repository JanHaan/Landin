with Landin.Targets;

package body Landin.Tests.Targets_Suite is

   use Landin.Targets;

   ------------------------------------------------------------------
   --  Every field of a description is asserted against a literal.  An
   --  unasserted field is a field the development host is free to supply,
   --  and a 32-bit description silently carrying 64-bit alignment is the
   --  exact defect these descriptions exist to prevent.
   ------------------------------------------------------------------

   procedure Check_Description
     (Item              : in out Landin.Testing.Context;
      Facts             : Target_Facts;
      Label             : String;
      Pointer_Bits      : Natural;
      Pointer_Align     : Natural;
      Stack_Align       : Natural;
      Widest            : Natural;
      Pointer_Bytes     : Natural);

   procedure Check_Description
     (Item              : in out Landin.Testing.Context;
      Facts             : Target_Facts;
      Label             : String;
      Pointer_Bits      : Natural;
      Pointer_Align     : Natural;
      Stack_Align       : Natural;
      Widest            : Natural;
      Pointer_Bytes     : Natural)
   is
   begin
      Landin.Testing.Check_Equal
        (Item, Name (Facts), Label, Label & " name");
      Landin.Testing.Check_Equal
        (Item, Natural (Pointer_Width (Facts)), Pointer_Bits,
         Label & " pointer width");
      Landin.Testing.Check_Equal
        (Item, Natural (Pointer_Alignment (Facts)), Pointer_Align,
         Label & " pointer alignment");
      Landin.Testing.Check_Equal
        (Item, Natural (Stack_Alignment (Facts)), Stack_Align,
         Label & " stack alignment");
      Landin.Testing.Check_Equal
        (Item, Natural (Max_Scalar_Alignment (Facts)), Widest,
         Label & " widest scalar alignment");
      Landin.Testing.Check
        (Item, Byte_Order (Facts) = Little, Label & " byte order");
      Landin.Testing.Check
        (Item, Frame_Pointer (Facts),
         Label & " keeps the frame pointer");
      Landin.Testing.Check_Equal
        (Item, Bytes (Pointer_Size (Facts)), Pointer_Bytes,
         Label & " pointer size in bytes");
   end Check_Description;

   procedure Descriptions_Do_Not_Follow_The_Host
     (Item : in out Landin.Testing.Context);

   procedure Descriptions_Do_Not_Follow_The_Host
     (Item : in out Landin.Testing.Context)
   is
   begin
      Check_Description
        (Item, Linux_X86_64, "linux-x86-64",
         Pointer_Bits  => 64,
         Pointer_Align => 8,
         Stack_Align   => 16,
         Widest        => 16,
         Pointer_Bytes => 8);

      Check_Description
        (Item, Synthetic_32, "synthetic-32",
         Pointer_Bits  => 32,
         Pointer_Align => 4,
         Stack_Align   => 8,
         Widest        => 8,
         Pointer_Bytes => 4);
   end Descriptions_Do_Not_Follow_The_Host;

   ------------------------------------------------------------------
   --  Alignment is walked over every Scalar_Size for both descriptions,
   --  from a named aggregate with no `others`, so adding a scalar size
   --  without saying how each target aligns it will not compile.
   ------------------------------------------------------------------

   procedure Alignments_Are_Stated_Per_Target
     (Item : in out Landin.Testing.Context);

   procedure Alignments_Are_Stated_Per_Target
     (Item : in out Landin.Testing.Context)
   is
      type Alignment_Table is array (Scalar_Size) of Natural;

      Hosted_Alignment : constant Alignment_Table :=
        [Byte_1  => 1,
         Byte_2  => 2,
         Byte_4  => 4,
         Byte_8  => 8,
         Byte_16 => 16];

      --  A 64-bit scalar aligns to eight here, and a 128-bit one does not
      --  align wider than eight either.  That is the difference a
      --  synthetic description has to be able to state.
      Small_Alignment : constant Alignment_Table :=
        [Byte_1  => 1,
         Byte_2  => 2,
         Byte_4  => 4,
         Byte_8  => 8,
         Byte_16 => 8];
   begin
      for Size in Scalar_Size loop
         Landin.Testing.Check_Equal
           (Item,
            Natural (Alignment_Of (Linux_X86_64, Size)),
            Hosted_Alignment (Size),
            "linux-x86-64 alignment of " & Scalar_Size'Image (Size));

         Landin.Testing.Check_Equal
           (Item,
            Natural (Alignment_Of (Synthetic_32, Size)),
            Small_Alignment (Size),
            "synthetic-32 alignment of " & Scalar_Size'Image (Size));
      end loop;
   end Alignments_Are_Stated_Per_Target;

   procedure Alignment_Refuses_To_Guess
     (Item : in out Landin.Testing.Context);

   procedure Alignment_Refuses_To_Guess
     (Item : in out Landin.Testing.Context)
   is
   begin
      Landin.Testing.Check
        (Item, Is_Power_Of_Two (1), "one is a power of two");
      Landin.Testing.Check
        (Item, Is_Power_Of_Two (16), "sixteen is a power of two");
      Landin.Testing.Check
        (Item, not Is_Power_Of_Two (12), "twelve is not a power of two");
      Landin.Testing.Check_Equal
        (Item, Natural (Align_Up (0, 8)), 0, "zero is already aligned");
      Landin.Testing.Check_Equal
        (Item, Natural (Align_Up (1, 8)), 8, "one rounds up to eight");
      Landin.Testing.Check_Equal
        (Item, Natural (Align_Up (8, 8)), 8, "eight is already aligned");
      Landin.Testing.Check_Equal
        (Item, Natural (Align_Up (9, 4)), 12, "nine rounds up to twelve");
      Landin.Testing.Check_Equal
        (Item, Natural (Align_Up (17, 16)), 32,
         "seventeen rounds up to thirty-two");

      --  A target offset must not be bounded by the host compiler's
      --  Integer.  This one is not representable in a 32-bit Natural.
      declare
         Far : constant Byte_Count := Byte_Count (2) ** 40;
      begin
         Landin.Testing.Check
           (Item, Align_Up (Far + 1, 8) = Far + 8,
            "layout arithmetic reaches past a host word");
      end;
   end Alignment_Refuses_To_Guess;

   procedure Overflow_Is_Reported (Item : in out Landin.Testing.Context);

   procedure Overflow_Is_Reported (Item : in out Landin.Testing.Context) is
      Ignored : Byte_Count;
   begin
      Ignored := Align_Up (Byte_Count'Last, 8);
      Landin.Testing.Fail (Item, "aligning past the end should be refused");
      pragma Assert (Ignored >= 0);
   exception
      when Landin.Compiler_Defect =>
         Landin.Testing.Check
           (Item, True, "aligning past the end raises rather than wrapping");
      when Landin.Host_Exhausted =>
         Landin.Testing.Fail
           (Item, "a layout overflow is a defect, not host exhaustion");
   end Overflow_Is_Reported;

   --  The power-of-two rule is the body's, in every mode.  It used to live
   --  only in a precondition, so a release build silently accepted an
   --  alignment of twelve and produced a layout nobody had described.
   procedure Odd_Alignment_Is_Refused
     (Item : in out Landin.Testing.Context);

   procedure Odd_Alignment_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Ignored : Byte_Count;
   begin
      Ignored := Align_Up (5, 12);
      Landin.Testing.Fail
        (Item, "an alignment that is not a power of two should be refused");
      pragma Assert (Ignored >= 0);
   exception
      when Landin.Compiler_Defect =>
         Landin.Testing.Check
           (Item, True, "a non-power-of-two alignment is refused");
   end Odd_Alignment_Is_Refused;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "targets", "descriptions do not follow the host",
         Descriptions_Do_Not_Follow_The_Host'Access);
      Landin.Testing.Register
        (Into, "targets", "alignments are stated per target",
         Alignments_Are_Stated_Per_Target'Access);
      Landin.Testing.Register
        (Into, "targets", "alignment refuses to guess",
         Alignment_Refuses_To_Guess'Access);
      Landin.Testing.Register
        (Into, "targets", "overflow is reported",
         Overflow_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "targets", "odd alignment is refused",
         Odd_Alignment_Is_Refused'Access);
   end Register;

end Landin.Tests.Targets_Suite;
