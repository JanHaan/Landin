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
      Pointer          => 64,
      Pointer_Align    => 8,
      Stack_Align      => 16,
      Order            => Little,
      Keeps_Frame      => True,
      Widest_Alignment => 16);

   function Synthetic_32 return Target_Facts is
     (Label            => Padded ("synthetic-32"),
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

   procedure Place
     (Into  : in out Placement;
      Size  : Scalar_Size;
      Facts : Target_Facts;
      At_Offset : out Byte_Count)
   is
      Wants : constant Byte_Alignment := Alignment_Of (Facts, Size);
   begin
      At_Offset := Align_Up (Into.Reach, Wants);
      Into.Reach := At_Offset + Byte_Count (Bytes (Size));

      if Wants > Into.Widest then
         Into.Widest := Wants;
      end if;
   end Place;

end Landin.Targets;
