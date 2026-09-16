--  Packed image algebra. Every bit belongs to the image, including holes.
--  This package performs no host or device access and allocates no storage.
package Landin.Packed is

   type Image is mod 2 ** 64;
   subtype Width is Positive range 1 .. 64;
   subtype Position is Natural range 0 .. 63;

   type Field is record
      First : Position := 0;
      Bits  : Width := 1;
      Count : Positive := 1;
   end record;
   type Field_Array is array (Positive range <>) of Field;
   type Encoding_Array is array (Positive range <>) of Image;

   --  Representation widths, not additional standalone scalar/ABI kinds.
   function Named_Width (Name : String) return Natural;

   --  Zero Bits/Storage denotes an ordinary byte-addressed field. A packed
   --  field records its element width and the containing image's carrier.
   --  Counts belong to the field shape, never to a per-element allocation.
   type Geometry is record
      First   : Position := 0;
      Bits    : Natural range 0 .. 64 := 0;
      Storage : Natural range 0 .. 64 := 0;
   end record;

   function Valid_Geometry
     (Shape : Geometry; Count : Natural := 1) return Boolean;

   function Mask (Bits : Width) return Image;
   function Fits (Value : Image; Bits : Width) return Boolean;
   function Fits (Part : Field; Bits : Width) return Boolean;
   function Valid (Fields : Field_Array; Bits : Width) return Boolean;
   function Claimed (Fields : Field_Array; Bits : Width) return Image;

   --  Element zero occupies the least significant slice of the field.
   --  Invalid descriptors, indexes and unrepresentable inserted values
   --  raise Compiler_Defect in both compiler modes; callers diagnose source
   --  errors or emit required runtime edges before using these helpers.
   function Extract
     (Raw : Image; Part : Field; Index : Natural := 0) return Image;
   function Insert
     (Raw, Value : Image; Part : Field; Index : Natural := 0) return Image;

   --  Enumeration holes are data. Validation returns membership, never a
   --  fabricated member or an assumption that the unmatched path is dead.
   function Valid_Encodings
     (Values : Encoding_Array; Bits : Width) return Boolean;
   function Contains (Values : Encoding_Array; Raw : Image) return Boolean;

   type Read_Mode is (No_Read, Normal_Read, Clear_On_Read);
   type Write_Mode is (No_Write, Normal_Write, One_Clears);
   type Reserved_Mode is (Preserve, Write_Zero, Write_One);
   type Access_Form is (Read_Image, Write_Image, Update_Field);

   type Register_Contract is record
      Bits     : Width := 32;
      Read     : Read_Mode := Normal_Read;
      Write    : Write_Mode := Normal_Write;
      Reserved : Reserved_Mode := Preserve;
      Named    : Image := 0;
   end record;

   type Access_Plan is record
      Allowed : Boolean := False;
      Reads   : Natural range 0 .. 1 := 0;
      Writes  : Natural range 0 .. 1 := 0;
   end record;

   --  Update_Field means a synthesized device RMW, not a local image edit.
   --  None is admitted: explicit read-image/local-edit/write-image is the
   --  source-visible two-event operation for a normal readable register.
   --  Raw writes with Preserve carry all reserved bits explicitly; they do
   --  not silently read the peripheral to obtain them.
   function Plan
     (Contract : Register_Contract; Form : Access_Form) return Access_Plan;
   function Legal_Write
     (Contract : Register_Contract; Raw : Image) return Boolean;

end Landin.Packed;
