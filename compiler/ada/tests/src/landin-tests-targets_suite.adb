with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Backend;
with Landin.Platform.Native;
with Landin.Targets;
with Landin.Targets.Capabilities;
with Landin.Types;

package body Landin.Tests.Targets_Suite is

   use Landin.Targets;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Write_Status;
   use type Landin.Targets.Capabilities.Backend_Kind;

   LF : constant Character := Character'Val (10);

   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

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

      Landin.Testing.Check
        (Item, Maximum_Object_Size (Linux_X86_64) = Byte_Count'Last,
         "a 64-bit target admits a 64-bit byte extent");
      Landin.Testing.Check
        (Item, Maximum_Object_Size (Synthetic_32) = 2 ** 32 - 1,
         "a 32-bit target admits only a 32-bit byte extent");
   end Descriptions_Do_Not_Follow_The_Host;

   procedure Backends_Are_Stated_Per_Target
     (Item : in out Landin.Testing.Context);

   procedure Backends_Are_Stated_Per_Target
     (Item : in out Landin.Testing.Context)
   is
      package Capabilities renames Landin.Targets.Capabilities;
   begin
      Landin.Testing.Check
        (Item,
         Capabilities.Backend_For (Linux_X86_64) =
           Capabilities.Linux_X86_64_ELF,
         "linux-x86-64 has the ELF backend");
      Landin.Testing.Check
        (Item,
         Capabilities.Backend_For (Synthetic_32) = Capabilities.No_Backend,
         "synthetic-32 has no backend");
   end Backends_Are_Stated_Per_Target;

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


   ------------------------------------------------------------------
   --  The recorded layout
   --
   --  R2.10 asks for synthetic 32-bit layout goldens before a Cortex
   --  backend exists, and the reason is the ordering: a description is
   --  the only thing a compiler with no such machine can be held to, and
   --  a table nobody wrote down is a model that drifts while every case
   --  still passes.  Both described targets are recorded, so the file
   --  says what differs between a 64-bit and a 32-bit machine as well as
   --  what each one is.
   ------------------------------------------------------------------

   type Size_List is array (Positive range <>) of Scalar_Size;

   function Layout_Text return String;

   function Layout_Text return String is
      package Unbounded renames Ada.Strings.Unbounded;

      Text : Unbounded.Unbounded_String;

      function Padded (Item : String; Wide : Positive) return String;

      function Padded (Item : String; Wide : Positive) return String is
         Room : constant Integer := Wide - Item'Length;
      begin
         if Room <= 0 then
            return Item;
         end if;
         return Item & [1 .. Room => ' '];
      end Padded;

      procedure Describe (Facts : Target_Facts);

      procedure Describe (Facts : Target_Facts) is
      begin
         Unbounded.Append
           (Text,
            LF & "target " & Name (Facts) & LF
            & "  pointer   " & Trimmed (Bit_Width'Image
                                          (Pointer_Width (Facts)))
            & " bits, aligned "
            & Trimmed (Byte_Alignment'Image (Pointer_Alignment (Facts)))
            & LF
            & "  stack     aligned "
            & Trimmed (Byte_Alignment'Image (Stack_Alignment (Facts)))
            & LF
            & "  widest    aligned "
            & Trimmed (Byte_Alignment'Image
                         (Max_Scalar_Alignment (Facts)))
            & LF
            & "  order     "
            & (if Byte_Order (Facts) = Little then "little" else "big")
            & LF & LF
            & "  type    bits  bytes  align" & LF);

         for Named in Landin.Types.Scalar_Name loop
            declare
               Size : constant Scalar_Size :=
                 Landin.Backend.Size_Of (Named, Facts);
            begin
               Unbounded.Append
                 (Text,
                  "  " & Padded (Landin.Types.Spelling (Named), 8)
                  & Padded
                      (Trimmed
                         (Bit_Width'Image
                            (if Named in Landin.Types.Integer_Name
                             then Landin.Types.Width (Named, Facts)
                             else 1)), 6)
                  & Padded (Trimmed (Positive'Image (Bytes (Size))), 7)
                  & Trimmed
                      (Byte_Alignment'Image (Alignment_Of (Facts, Size)))
                  & LF);
            end;
         end loop;

         --  [0750]'s rule, worked: the same three fields in two orders.
         --  A reader can check the padding by counting, and a layout that
         --  reordered fields would make the two lines agree.
         declare
            procedure Row (Label : String; Sizes : Size_List);

            procedure Row (Label : String; Sizes : Size_List) is
               Made  : Placement := Empty_Placement;
               Where : Byte_Count;
               Line  : Unbounded.Unbounded_String;
            begin
               for Each of Sizes loop
                  Place (Made, Each, Facts, Where);
                  Unbounded.Append
                    (Line, Trimmed (Byte_Count'Image (Where)) & " ");
               end loop;

               Unbounded.Append
                 (Text,
                  "  " & Padded (Label, 16)
                  & Padded (Unbounded.To_String (Line), 12)
                  & Padded (Trimmed (Byte_Count'Image (Size_Of (Made))), 7)
                  & Trimmed (Byte_Alignment'Image (Alignment_Of (Made)))
                  & LF);
            end Row;
         begin
            Unbounded.Append
              (Text, LF & "  aggregate       offsets     size   align"
               & LF);
            Row ("u8 u32 u8", [Byte_1, Byte_4, Byte_1]);
            Row ("u8 u8 u32", [Byte_1, Byte_1, Byte_4]);
            Row ("u8 usize", [Byte_1, Pointer_Size (Facts)]);
            Row ("u64 u8", [Byte_8, Byte_1]);
         end;
      end Describe;
   begin
      Unbounded.Append
        (Text,
         "# Generated by landin_tests --record.  Do not edit." & LF
         & "# Every described target, and what Landin.Targets says a"
         & " value of each" & LF
         & "# scalar type measures on it.  A bool is one bit wide"
         & " [0150] and occupies" & LF
         & "# the next machine width [1870], which is why its two"
         & " numbers differ." & LF);

      Describe (Linux_X86_64);
      Describe (Synthetic_32);
      return Unbounded.To_String (Text);
   end Layout_Text;

   procedure Record_Artefact (Path : String; Wrote : out Boolean) is
      Host : Landin.Platform.Native.Native_Filesystem;
      Status : Landin.Platform.Write_Status;
   begin
      Host.Write_File (Path, Layout_Text, Status);
      Wrote := Status = Landin.Platform.Write_Ok;
   end Record_Artefact;

   --  Reads the recorded file, deliberately: the artefact on disk is the
   --  thing under test, and a fake copy of it would prove nothing about
   --  what a reader of this repository will find.
   procedure The_Recorded_Layout_Is_Current
     (Item : in out Landin.Testing.Context);

   procedure The_Recorded_Layout_Is_Current
     (Item : in out Landin.Testing.Context)
   is
      package Unbounded renames Ada.Strings.Unbounded;

      Host     : Landin.Platform.Native.Native_Filesystem;
      Path     : constant String := "../tests/layout.targets";
      Recorded : Unbounded.Unbounded_String;
      Status   : Landin.Platform.Read_Status;
   begin
      Host.Read_File (Path, Recorded, Status);

      if Status /= Landin.Platform.Read_Ok then
         Landin.Testing.Fail
           (Item,
            "the recorded layout is missing; regenerate it with"
            & " ./scripts/test.sh --record");
         return;
      end if;

      Landin.Testing.Check_Equal
        (Item, Unbounded.To_String (Recorded), Layout_Text,
         "the recorded layout is what the target model says now");
   end The_Recorded_Layout_Is_Current;

   --  [0750]: fields keep the order you wrote them, with natural
   --  alignment and padding in between.  The order is the evidence: the
   --  same three fields written two ways occupy different numbers of
   --  bytes, and a layout that reordered them to save padding would make
   --  both answers the same and break the sentence.
   procedure Fields_Keep_The_Order_They_Were_Written
     (Item : in out Landin.Testing.Context);

   procedure Fields_Keep_The_Order_They_Were_Written
     (Item : in out Landin.Testing.Context)
   is
      Wide  : Placement := Empty_Placement;
      Tight : Placement := Empty_Placement;
      Where : Byte_Count;
   begin
      --  u8, u32, u8: the second field pays three bytes of padding and
      --  the third leaves the whole rounded up.
      Place (Wide, Byte_1, Linux_X86_64, Where);
      Landin.Testing.Check_Equal
        (Item, Natural (Where), 0, "the first field begins at zero");
      Place (Wide, Byte_4, Linux_X86_64, Where);
      Landin.Testing.Check_Equal
        (Item, Natural (Where), 4, "a four-byte field aligns to four");
      Place (Wide, Byte_1, Linux_X86_64, Where);
      Landin.Testing.Check_Equal
        (Item, Natural (Where), 8, "and the byte after it follows on");

      Landin.Testing.Check_Equal
        (Item, Natural (Extent_Of (Wide)), 9, "the fields reach nine");
      Landin.Testing.Check_Equal
        (Item, Natural (Size_Of (Wide)), 12,
         "and the whole rounds up to its own alignment");
      Landin.Testing.Check
        (Item, Alignment_Of (Wide) = 4,
         "an aggregate aligns as widely as its widest field");

      --  u8, u8, u32: the same three fields, written so that no padding
      --  is needed at all.
      Place (Tight, Byte_1, Linux_X86_64, Where);
      Place (Tight, Byte_1, Linux_X86_64, Where);
      Place (Tight, Byte_4, Linux_X86_64, Where);
      Landin.Testing.Check_Equal
        (Item, Natural (Where), 4, "the wide field still aligns to four");
      Landin.Testing.Check_Equal
        (Item, Natural (Size_Of (Tight)), 8,
         "and the order that needs no padding is smaller");
   end Fields_Keep_The_Order_They_Were_Written;

   --  The layout follows the description and not the machine running the
   --  compiler, which for an aggregate means the pointer-width field is
   --  where the two descriptions come apart.
   procedure A_Layout_Follows_The_Target_And_Not_The_Host
     (Item : in out Landin.Testing.Context);

   procedure A_Layout_Follows_The_Target_And_Not_The_Host
     (Item : in out Landin.Testing.Context)
   is
      Wide   : Placement := Empty_Placement;
      Narrow : Placement := Empty_Placement;
      Where  : Byte_Count;
   begin
      --  u8 then usize, on each description.
      Place (Wide, Byte_1, Linux_X86_64, Where);
      Place (Wide, Pointer_Size (Linux_X86_64), Linux_X86_64, Where);
      Landin.Testing.Check_Equal
        (Item, Natural (Where), 8,
         "a 64-bit pointer field aligns to eight");
      Landin.Testing.Check_Equal
        (Item, Natural (Size_Of (Wide)), 16, "and the whole is sixteen");

      Place (Narrow, Byte_1, Synthetic_32, Where);
      Place (Narrow, Pointer_Size (Synthetic_32), Synthetic_32, Where);
      Landin.Testing.Check_Equal
        (Item, Natural (Where), 4,
         "a 32-bit pointer field aligns to four");
      Landin.Testing.Check_Equal
        (Item, Natural (Size_Of (Narrow)), 8, "and the whole is eight");
   end A_Layout_Follows_The_Target_And_Not_The_Host;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "targets", "fields keep the order they were written",
         Fields_Keep_The_Order_They_Were_Written'Access);
      Landin.Testing.Register
        (Into, "targets", "a layout follows the target and not the host",
         A_Layout_Follows_The_Target_And_Not_The_Host'Access);
      Landin.Testing.Register
        (Into, "targets", "the recorded layout is current",
         The_Recorded_Layout_Is_Current'Access);
      Landin.Testing.Register
        (Into, "targets", "descriptions do not follow the host",
         Descriptions_Do_Not_Follow_The_Host'Access);
      Landin.Testing.Register
        (Into, "targets", "backends are stated per target",
         Backends_Are_Stated_Per_Target'Access);
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
