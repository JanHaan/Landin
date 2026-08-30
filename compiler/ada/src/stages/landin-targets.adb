with Landin.Evidence;

package body Landin.Targets is

   function Padded (Text : String) return String;

   function Padded (Text : String) return String is
      Result : String (1 .. Name_Length) := [others => ' '];
      Length : constant Natural := Natural'Min (Text'Length, Name_Length);
   begin
      Result (1 .. Length) := Text (Text'First .. Text'First + Length - 1);
      return Result;
   end Padded;

   function Linux_X86_64 return Target_Facts is
     (Label            => Padded ("linux-x86-64"),
      Machine          => X86_64,
      Pointer          => 64,
      Pointer_Align    => 8,
      Stack_Align      => 16,
      Order            => Little,
      Keeps_Frame      => True,
      Widest_Alignment => 16);

   function Synthetic_32 return Target_Facts is
     (Label            => Padded ("synthetic-32"),
      Machine          => Synthetic_32_Architecture,
      Pointer          => 32,
      Pointer_Align    => 4,
      Stack_Align      => 8,
      Order            => Little,
      Keeps_Frame      => True,
      --  A 64-bit scalar on this machine aligns to eight, and nothing
      --  aligns wider; that is the whole point of describing it here
      --  rather than reading it off the development host.
      Widest_Alignment => 8);

   function Name (Facts : Target_Facts) return String is
      Last : Natural := Facts.Label'Last;
   begin
      while Last >= Facts.Label'First and then Facts.Label (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return Facts.Label (Facts.Label'First .. Last);
   end Name;

   function Architecture_Of (Facts : Target_Facts) return Architecture
     is (Facts.Machine);

   function Pointer_Width (Facts : Target_Facts) return Bit_Width
     is (Facts.Pointer);

   function Pointer_Alignment (Facts : Target_Facts) return Byte_Alignment
     is (Facts.Pointer_Align);

   function Stack_Alignment (Facts : Target_Facts) return Byte_Alignment
     is (Facts.Stack_Align);

   function Byte_Order (Facts : Target_Facts) return Endianness
     is (Facts.Order);

   function Frame_Pointer (Facts : Target_Facts) return Boolean
     is (Facts.Keeps_Frame);

   function Max_Scalar_Alignment (Facts : Target_Facts) return Byte_Alignment
     is (Facts.Widest_Alignment);

   function Alignment_Of
     (Facts : Target_Facts; Size : Scalar_Size) return Byte_Alignment
     is (Byte_Alignment'Min (Byte_Alignment (Bytes (Size)),
                             Facts.Widest_Alignment));

   function Pointer_Size (Facts : Target_Facts) return Scalar_Size is
   begin
      case Natural (Facts.Pointer) is
         when 8      => return Byte_1;
         when 16     => return Byte_2;
         when 32     => return Byte_4;
         when 64     => return Byte_8;
         when 128    => return Byte_16;
         when others =>
            raise Compiler_Defect
              with "target pointer width is not a described scalar size";
      end case;
   end Pointer_Size;

   function Maximum_Object_Size (Facts : Target_Facts) return Byte_Count
     is (2 ** Natural (Facts.Pointer) - 1);

   function Evidence_Cell_Size (Facts : Target_Facts) return Byte_Count
     is (Byte_Count (Bytes (Pointer_Size (Facts))));

   function Evidence_Size_Offset (Facts : Target_Facts) return Byte_Count
     is (Evidence_Cell_Size (Facts)
         * Byte_Count (Landin.Evidence.Size_Position));

   function Evidence_Alignment_Offset
     (Facts : Target_Facts) return Byte_Count
     is (Evidence_Cell_Size (Facts)
         * Byte_Count (Landin.Evidence.Alignment_Position));

   function Evidence_Function_Offset
     (Facts : Target_Facts;
      Declaration_Order : Positive) return Byte_Count
   is
      Cell : constant Byte_Count := Evidence_Cell_Size (Facts);
      Position : constant Byte_Count :=
        Byte_Count (Landin.Evidence.Function_Position (Declaration_Order));
   begin
      if Position > Byte_Count'Last / Cell then
         raise Compiler_Defect with "evidence-table offset overflow";
      end if;
      return Position * Cell;
   end Evidence_Function_Offset;

   function Evidence_Table_Size
     (Facts : Target_Facts;
      Function_Count : Natural) return Byte_Count
   is
      Cell    : constant Byte_Count := Evidence_Cell_Size (Facts);
      Count   : constant Byte_Count := Byte_Count (Function_Count);
      Entries : Byte_Count;
   begin
      if Count > Byte_Count'Last - 2 then
         raise Compiler_Defect with "evidence-table size overflow";
      end if;
      Entries := Byte_Count (Landin.Evidence.Entry_Count (Function_Count));
      if Entries > Byte_Count'Last / Cell
        or else Entries > Maximum_Object_Size (Facts) / Cell
      then
         raise Compiler_Defect with "evidence-table size overflow";
      end if;
      --  A pointer-width cell is aligned to pointer alignment on every
      --  described target, so the contiguous extent is already aligned.
      return Entries * Cell;
   end Evidence_Table_Size;

   function Evidence_Table_Alignment
     (Facts : Target_Facts) return Byte_Alignment
     is (Pointer_Alignment (Facts));

   function Is_Power_Of_Two (Value : Byte_Alignment) return Boolean is
      Remaining : Natural := Natural (Value);
   begin
      while Remaining mod 2 = 0 loop
         Remaining := Remaining / 2;
      end loop;
      return Remaining = 1;
   end Is_Power_Of_Two;

   function Align_Up
     (Offset : Byte_Count; Alignment : Byte_Alignment) return Byte_Count
   is
      Step      : constant Byte_Count := Byte_Count (Alignment);
      Remainder : constant Byte_Count := Offset mod Step;
   begin
      if not Is_Power_Of_Two (Alignment) then
         raise Compiler_Defect
           with "alignment is not a power of two";
      end if;

      if Remainder = 0 then
         return Offset;
      end if;

      --  A layout that cannot be expressed is a defect in the compiler or
      --  an impossible target description, not a host that ran out of
      --  something.  R0.50 keeps those two apart on purpose.
      if Byte_Count'Last - (Step - Remainder) < Offset then
         raise Compiler_Defect with "layout offset overflow";
      end if;

      return Offset + (Step - Remainder);
   end Align_Up;

   ------------------------------------------------------------------
   --  Placement
   ------------------------------------------------------------------

   function Empty_Placement return Placement is (others => <>);

   function Extent_Of (Item : Placement) return Byte_Count
     is (Item.Reach);

   function Alignment_Of (Item : Placement) return Byte_Alignment
     is (Item.Widest);

   function Size_Of (Item : Placement) return Byte_Count
     is (Align_Up (Item.Reach, Item.Widest));

   function Can_Place
     (Into      : Placement;
      Size      : Byte_Count;
      Alignment : Byte_Alignment;
      Maximum   : Byte_Count) return Boolean
   is
      Step      : constant Byte_Count := Byte_Count (Alignment);
      Remainder : constant Byte_Count := Into.Reach mod Step;
      Padding   : constant Byte_Count :=
        (if Remainder = 0 then 0 else Step - Remainder);
      Widest    : constant Byte_Alignment :=
        Byte_Alignment'Max (Into.Widest, Alignment);
      Finish_Step : constant Byte_Count := Byte_Count (Widest);
      At_Offset : Byte_Count;
      Reach     : Byte_Count;
      Finish_Remainder : Byte_Count;
      Finish_Padding   : Byte_Count;
   begin
      if not Is_Power_Of_Two (Alignment)
        or else Into.Reach > Maximum
        or else Padding > Maximum - Into.Reach
      then
         return False;
      end if;

      At_Offset := Into.Reach + Padding;
      if Size > Maximum - At_Offset then
         return False;
      end if;

      Reach := At_Offset + Size;
      Finish_Remainder := Reach mod Finish_Step;
      Finish_Padding :=
        (if Finish_Remainder = 0
         then 0 else Finish_Step - Finish_Remainder);
      return Finish_Padding <= Maximum - Reach;
   end Can_Place;

   procedure Place
     (Into      : in out Placement;
      Size      : Byte_Count;
      Alignment : Byte_Alignment;
      At_Offset : out Byte_Count)
   is
   begin
      if not Can_Place (Into, Size, Alignment, Byte_Count'Last) then
         raise Compiler_Defect with "aggregate placement overflow";
      end if;

      At_Offset := Align_Up (Into.Reach, Alignment);
      Into.Reach := At_Offset + Size;
      Into.Widest := Byte_Alignment'Max (Into.Widest, Alignment);
   end Place;

   procedure Place
     (Into  : in out Placement;
      Size  : Scalar_Size;
      Facts : Target_Facts;
      At_Offset : out Byte_Count)
   is
      Wants : constant Byte_Alignment := Alignment_Of (Facts, Size);
   begin
      Place
        (Into, Byte_Count (Bytes (Size)), Wants, At_Offset);
   end Place;

end Landin.Targets;
