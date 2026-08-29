--  Test-only corruption hooks for `Landin.IR`.
--
--  Landin.IR's builder holds every legitimate construction to a Unit
--  that Nth_Value and every other reader can index without raising.  A
--  verifier that says nothing about a case that never reaches it says
--  nothing about the check, so the verifier suite needs to reach a Unit
--  whose bytes disagree with what the builder promised and prove the
--  rule refuses that Unit anyway.
--
--  This package is a child of `Landin.IR` and therefore sees the parent's
--  private record fields; and it is a source file under
--  `compiler/ada/tests/src/`, which `landin_tests.gpr` includes and
--  `landin_lib.gpr` and `refine.gpr` do not.  That combination is the
--  boundary a review can grep: no production build reaches this package
--  because the library it would be linked from was not compiled with it.
--  If a future change adds this source directory to a production project
--  the elaboration harness below has to change too.
--
--  Every entry point is named "Overwrite" or "Truncate" so a review can
--  find each in one grep and know it is not a production path.

package Landin.IR.Testing_Support is

   --  Replaces the array datum's image run with the given base and
   --  count, and sets Has_Image accordingly.  Used to build a Unit that
   --  claims a run past the vector's end, a run overlapping another
   --  item's, or a run so short that a byte in the shared vector is
   --  orphaned.  The vector itself is not touched here; the caller
   --  chooses how many bytes the vector holds via Append_Image_Bytes.
   procedure Overwrite_Image_Run
     (Into  : in out Unit;
      Item  : Item_Id;
      First : Natural;
      Count : Natural)
     with Pre => Holds (Into, Item)
                 and then Result_Of (Into, Item)
                          = Landin.Types.Fixed_Array;

   --  Appends the given number of zero-value bytes to the shared image
   --  vector.  Used to fabricate a vector whose length disagrees with
   --  what the sum of per-item image runs would predict.
   procedure Append_Image_Bytes
     (Into  : in out Unit;
      Count : Natural);

   --  Removes the trailing bytes from the shared image vector.  Used
   --  when the corruption case needs a run to walk past the vector's
   --  end -- the run's Count is already set to the too-large value by
   --  Overwrite_Image_Run and this truncates the vector below it.
   procedure Truncate_Image_Bytes
     (Into : in out Unit;
      Down_To : Natural)
     with Pre => Down_To <= Image_Byte_Count (Into);

   function Image_Byte_Count (Of_Unit : Unit) return Natural;

   --  Corrupts root metadata without exposing a nominal constructor.  The
   --  supplied identity is either one obtained from the public unit registry
   --  or No_Nominal_Type; out-of-range identities remain unconstructible.
   procedure Overwrite_Item_Nominal
     (Into   : in out Unit;
      Item   : Item_Id;
      Nominal : Nominal_Type_Id)
     with Pre => Holds (Into, Item);

   procedure Overwrite_Slot_Nominal
     (Into   : in out Unit;
      Item   : Item_Id;
      Slot   : Slot_Id;
      Nominal : Nominal_Type_Id)
     with Pre => Holds (Into, Item)
                 and then Holds (Into, Item, Slot);

end Landin.IR.Testing_Support;
