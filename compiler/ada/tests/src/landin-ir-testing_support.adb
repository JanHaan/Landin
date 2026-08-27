package body Landin.IR.Testing_Support is

   function Image_Byte_Count (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Images.Length));

   procedure Overwrite_Image_Run
     (Into  : in out Unit;
      Item  : Item_Id;
      First : Natural;
      Count : Natural)
   is
      Held : Item_Record := Into.Items (Positive (Item));
   begin
      Held.Image := (First => First, Count => Count);
      Held.Has_Image := Count > 0;
      Into.Items (Positive (Item)) := Held;
   end Overwrite_Image_Run;

   procedure Append_Image_Bytes
     (Into  : in out Unit;
      Count : Natural)
   is
   begin
      for Ignored in 1 .. Count loop
         pragma Unreferenced (Ignored);
         Into.Images.Append (0);
      end loop;
   end Append_Image_Bytes;

   procedure Truncate_Image_Bytes
     (Into : in out Unit;
      Down_To : Natural)
   is
   begin
      while Natural (Into.Images.Length) > Down_To loop
         Into.Images.Delete_Last;
      end loop;
   end Truncate_Image_Bytes;

end Landin.IR.Testing_Support;
