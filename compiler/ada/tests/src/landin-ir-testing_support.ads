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

   --  Evidence operations have public builders whose preconditions make an
   --  out-of-range identity or entry unconstructible.  These hooks damage a
   --  value after construction so each verifier rule remains executable.
   procedure Overwrite_Value_Evidence
     (Into     : in out Unit;
      Item     : Item_Id;
      Value    : Value_Id;
      Evidence : Evidence_Id)
     with Pre => Holds (Into, Item, Value)
                 and then Op_Of (Into, Item, Value)
                   in Evidence_Address | Evidence_Function;

   procedure Overwrite_Value_Evidence_Entry
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Value_Id;
      Which : Natural)
     with Pre => Holds (Into, Item, Value)
                 and then Op_Of (Into, Item, Value) = Evidence_Function;

   procedure Overwrite_Value_Signature
     (Into     : in out Unit;
      Item     : Item_Id;
      Value    : Value_Id;
      Signature : Signature_Id)
     with Pre => Holds (Into, Item, Value);

   --  Release-mode verifier evidence: corrupt metadata only after a valid
   --  unit has been built, bypassing builder preconditions deliberately.
   type Item_Run_Kind is
     (Slot_Run, Parameter_Run, Block_Run, Value_Run, Field_Run);

   procedure Overwrite_Item_Run
     (Into : in out Unit; Item : Item_Id; Which : Item_Run_Kind;
      First, Count : Natural)
     with Pre => Holds (Into, Item);

   procedure Overwrite_Parameter
     (Into : in out Unit; Item : Item_Id; Index : Positive; Slot : Slot_Id)
     with Pre => Holds (Into, Item)
                 and then Index <= Parameter_Count (Into, Item);

   procedure Overwrite_Nominal_Run
     (Into : in out Unit; Nominal : Nominal_Type_Id; First, Count : Natural)
     with Pre => Has_Nominal_Shape (Into, Nominal);

   --  Complete-child, image and indirect witnesses can be corrupted only
   --  after construction, so assertions do not stand in for verification.
   procedure Overwrite_Shape
     (Into : in out Unit; Position : Positive; Shape : Field_Shape)
     with Pre => Position <= Variant_Field_Shape_Count (Into);

   procedure Overwrite_Array_Element_Run
     (Into : in out Unit; Item : Item_Id; First : Natural;
      Slot : Slot_Id := No_Slot)
     with Pre => Holds (Into, Item)
                 and then (Slot = No_Slot or else Holds (Into, Item, Slot));

   procedure Overwrite_Image_Descriptor
     (Into : in out Unit; Item : Item_Id; Position : Positive;
      Image : Aggregate_Field_Image)
     with Pre => Holds (Into, Item)
                 and then Position <= Aggregate_Field_Image_Count
                   (Into, Item);

   procedure Overwrite_Descriptor_Run
     (Into : in out Unit; Item : Item_Id; First, Count : Natural)
     with Pre => Holds (Into, Item);

   procedure Overwrite_Signature_Parameter
     (Into : in out Unit; Signature : Signature_Id; Index : Positive;
      Part : Signature_Part)
     with Pre => Holds (Into, Signature)
                 and then Index <= Signature_Parameter_Count
                   (Into, Signature);

   procedure Overwrite_Signature_Result
     (Into : in out Unit; Signature : Signature_Id; Index : Positive;
      Part : Signature_Part)
     with Pre => Holds (Into, Signature)
                 and then Index <= Signature_Result_Count (Into, Signature);

   procedure Overwrite_Signature_Errors
     (Into : in out Unit; Signature : Signature_Id; Errors : Atom_Set_Id)
     with Pre => Holds (Into, Signature);

   procedure Overwrite_Signature_Source
     (Into : in out Unit; Signature : Signature_Id; Index : Positive;
      Source : Return_Source_Association)
     with Pre => Holds (Into, Signature);

   procedure Overwrite_Evidence_Dispatch
     (Into : in out Unit; Evidence : Evidence_Id; Which : Positive;
      Signature : Signature_Id)
     with Pre => Holds (Into, Evidence)
                 and then Which <= Evidence_Entry_Count (Into, Evidence);

   procedure Overwrite_Item_Signature
     (Into : in out Unit; Item : Item_Id; Signature : Signature_Id)
     with Pre => Holds (Into, Item);

   procedure Overwrite_Indirect_Address_Slot
     (Into : in out Unit; Item : Item_Id; Value : Value_Id; Slot : Slot_Id)
     with Pre => Holds (Into, Item, Value)
                 and then Op_Of (Into, Item, Value)
                   in Load_Indirect | Store_Indirect;

   procedure Overwrite_Operand
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Index : Positive; Operand : Value_Id)
     with Pre => Holds (Into, Item, Value)
                 and then Index <= Operand_Count (Into, Item, Value);

   procedure Overwrite_Value_Atoms
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Atoms : Atom_Set_Id)
     with Pre => Holds (Into, Item, Value);

   procedure Overwrite_Value_Type
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Result : Landin.Types.Type_Kind)
     with Pre => Holds (Into, Item, Value);

   procedure Overwrite_Pointee
     (Into : in out Unit; Pointee : Pointee_Id; Shape : Field_Shape)
     with Pre => Holds (Into, Pointee);

   procedure Overwrite_Value_Pointee
     (Into : in out Unit; Item : Item_Id; Value : Value_Id;
      Pointee : Pointee_Id)
     with Pre => Holds (Into, Item, Value);

end Landin.IR.Testing_Support;
