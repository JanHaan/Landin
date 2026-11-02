--  A selection policy: which of an SVD's registers become Landin, and how
--  each may be read and written (D556).
--
--  The policy is JSON, read by Landin.Json, so `refine svd` reads it with
--  nothing but refine.  It names the SVD it was reviewed against by device,
--  version and SHA-256; the notice its modules carry; where the outputs
--  go; the selected peripherals and their registers in order; each
--  selected register's read, write and reserved-bit policy; the fields
--  whose vendor enumeration is read as a plain number; and the reviewed
--  corrections of what the SVD says a register resets to or where it
--  lies; the description's identity and core where the SVD does not say
--  them; and peripherals the SVD lacks.  A member it
--  does not know is refused, except `provenance`, which is the reviewer's
--  and is not read.

with Ada.Containers.Indefinite_Vectors;

package Landin.Devices.Policies is

   type Read_Policy is (Normal_Read, Modify_Read, Refused_Read);
   type Write_Policy is (Normal_Write, One_Clears_Write, Refused_Write);
   type Reserved_Policy is (Write_Zero, Preserve);

   type Register_Choice is record
      Peripheral : US.Unbounded_String;
      Register : US.Unbounded_String;
      Read : Read_Policy := Normal_Read;
      Write : Write_Policy := Normal_Write;
      Reserved : Reserved_Policy := Write_Zero;
      Has_Write_Mask : Boolean := False;
      Write_Mask : Word := 0;
      --  The mask as the policy writes it, which the correspondence keeps.
      Write_Mask_Text : US.Unbounded_String;
      --  A reviewed reset mask, replacing what is derived from the SVD.
      Has_Reset_Mask : Boolean := False;
      Reset_Mask : Word := 0;
      --  A reviewed reset value, replacing the SVD's, and where the
      --  reviewer read it.
      Has_Reset_Value : Boolean := False;
      Reset_Value : Word := 0;
      Reset_Source : US.Unbounded_String;
      --  A reviewed offset, replacing the SVD's, and where the reviewer
      --  read it (D704).
      Has_Offset : Boolean := False;
      Offset : Word := 0;
      Offset_Source : US.Unbounded_String;
   end record;

   package Choice_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Register_Choice);

   type Peripheral_Choice is record
      Name : US.Unbounded_String;
      --  Its registers are Registers (First .. Last).
      First : Positive := 1;
      Last : Natural := 0;
   end record;

   package Peripheral_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Peripheral_Choice);

   package Text_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   --  A reviewed correction of where a field lies, that it is not a
   --  field, or a field the SVD lacks, with where the reviewer read it.
   type Field_Correction is record
      Key : US.Unbounded_String;
      Omit : Boolean := False;
      --  A field the SVD lacks, added at Low .. High with Field_Access,
      --  one of the SVD's access words (D652).
      Add : Boolean := False;
      Field_Access : US.Unbounded_String;
      Low, High : Natural := 0;
      Source : US.Unbounded_String;
   end record;

   package Correction_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Field_Correction);

   --  A reviewed correction of the SVD's interrupts: one added or moved
   --  to Value, or every pair of its name removed, with its source.
   type Interrupt_Correction is record
      Name : US.Unbounded_String;
      Omit : Boolean := False;
      Value : Word := 0;
      Source : US.Unbounded_String;
   end record;

   package Interrupt_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Interrupt_Correction);

   --  A peripheral the SVD lacks, which a reviewed policy adds with the
   --  source it was read from (D705).  Its registers are written as the
   --  SVD's own XML, which the projection reads as if the SVD gave them.
   type Peripheral_Addition is record
      Name : US.Unbounded_String;
      Source : US.Unbounded_String;
      Xml : US.Unbounded_String;
   end record;

   package Addition_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Peripheral_Addition);

   --  The interrupt model of the core a policy names (D700, D701): an NVIC
   --  or Hazard3's Xh3irq takes interrupt n at slot 16 + n, and a core
   --  whose SVD interrupts are an interrupt matrix's sources takes none of
   --  them as a slot.
   type Core_Choice is
     (From_Svd, Hazard3, Esp_Rv32imc, Esp_Rv32imac_Clic);

   type Policy is record
      Device : US.Unbounded_String;
      --  The description's identity, when it is not the SVD's device name
      --  in lowercase, and its core, when the SVD's cpu does not say it.
      Identity : US.Unbounded_String;
      Core : Core_Choice := From_Svd;
      Svd_Version : US.Unbounded_String;
      Svd_Sha256 : US.Unbounded_String;
      --  Each line follows `-- ` at the head of every register module.
      Notice : Text_Vectors.Vector;
      --  Where the register modules' import root is, under the output
      --  directory; the directory each peripheral's module is in, under
      --  that root; and the correspondence and manifest, under it too.
      Modules : US.Unbounded_String;
      Prefix : US.Unbounded_String;
      Correspondence : US.Unbounded_String;
      Manifest : US.Unbounded_String;
      --  Where interrupts.ldn goes, under the output directory.
      Description : US.Unbounded_String;
      Peripherals : Peripheral_Vectors.Vector;
      Registers : Choice_Vectors.Vector;
      --  `PERIPHERAL.REGISTER.FIELD` for each field read as a number.
      Numeric : Text_Vectors.Vector;
      --  `PERIPHERAL.REGISTER.FIELD`'s reviewed corrections.
      Fields : Correction_Vectors.Vector;
      --  The interrupts' reviewed corrections, in the policy's order.
      Interrupts : Interrupt_Vectors.Vector;
      --  The peripherals a reviewer adds, in the policy's order.
      Additions : Addition_Vectors.Vector;
   end record;

   --  The text a policy's core is written as in a description.
   function Core_Name (Core : Core_Choice) return String;

   procedure Read
     (Text : String; Into : out Policy; Problem : out Fault);

   function Is_Numeric (Of_Policy : Policy; Key : String) return Boolean;

   --  The correction of field Key, or zero.
   function Correction_Of (Of_Policy : Policy; Key : String) return Natural;

end Landin.Devices.Policies;
