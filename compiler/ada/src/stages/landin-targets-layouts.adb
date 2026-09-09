package body Landin.Targets.Layouts is

   use type Landin.Layouts.Policy;

   function Make
     (Fields  : Field_Extent_Array;
      Policy  : Landin.Layouts.Policy := Landin.Layouts.Natural;
      Maximum : Byte_Count := Byte_Count'Last) return Plan
   is
      Made : Plan (Fields'Length);

      procedure Place_Order (Into : in out Plan);

      procedure Place_Order (Into : in out Plan) is
         Layout : Placement := Empty_Placement;
      begin
         for Position of Into.Order loop
            declare
               Field : constant Field_Extent :=
                 Fields (Fields'First + Position - 1);
            begin
               if not Can_Place
                 (Layout, Field.Size, Field.Alignment, Byte_Count'Last)
               then
                  raise Landin.Compiler_Defect with
                    "invalid or overflowing field placement";
               end if;
               Place (Layout, Field.Size, Field.Alignment,
                      Into.Offsets (Position));
            end;
         end loop;
         Into.Size := Size_Of (Layout);
         Into.Alignment := Alignment_Of (Layout);
      end Place_Order;
   begin
      for Position in Made.Order'Range loop
         Made.Order (Position) := Position;
      end loop;
      Place_Order (Made);
      Made.Natural_Size := Made.Size;
      if Policy = Landin.Layouts.Optimal then
         declare
            Candidate : Plan := Made;
            Alignment : Byte_Alignment := Byte_Alignment'Last;
            Count : Natural := 0;
         begin
            --  Alignments are validated powers of two.  Thirteen stable
            --  buckets avoid quadratic sorting and allocate no per-byte
            --  metadata, even for a field representing a huge fixed array.
            loop
               for Position in Made.Order'Range loop
                  if Fields (Fields'First + Position - 1).Alignment
                    = Alignment
                  then
                     Count := Count + 1;
                     Candidate.Order (Count) := Position;
                  end if;
               end loop;
               exit when Alignment = 1;
               Alignment := Alignment / 2;
            end loop;
            --  An unpadded unit may make the candidate larger.  Even if
            --  its final padding overflows, the valid natural plan wins.
            begin
               Place_Order (Candidate);
               if Candidate.Size < Made.Size then
                  Candidate.Saved_Bytes := Made.Size - Candidate.Size;
                  Made := Candidate;
               end if;
            exception
               when Landin.Compiler_Defect =>
                  null;
            end;
         end;
      end if;
      if Made.Size > Maximum then
         raise Landin.Compiler_Defect with
           "field placement exceeds the target object limit";
      end if;
      return Made;
   end Make;

   function Fits
     (Fields  : Field_Extent_Array;
      Policy  : Landin.Layouts.Policy := Landin.Layouts.Natural;
      Maximum : Byte_Count := Byte_Count'Last) return Boolean
   is
   begin
      declare
         Made : constant Plan := Make (Fields, Policy, Maximum);
      begin
         return Made.Size <= Maximum;
      end;
   exception
      when Landin.Compiler_Defect =>
         return False;
   end Fits;

end Landin.Targets.Layouts;
