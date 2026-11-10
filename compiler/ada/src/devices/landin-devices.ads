--  Learning a device from its CMSIS-SVD file (D555-D558).
--
--  `refine svd` reads a vendor's SVD and a selection policy and writes
--  Landin: one register module per selected peripheral, a correspondence
--  that records what each selected register and field was in the SVD, a
--  manifest of what it wrote, and the generated half of the device's
--  description, its interrupts (D542).  This package holds what the
--  importer's parts share: what went wrong and where, the files made, and
--  the spellings the SVD's numbers and names are read in.
--
--  Nothing here or below reads a file.  The command reads the two inputs
--  and replaces the outputs through Landin.Platform, so the projection is a
--  function of two byte strings and a test can run it on literals.

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Landin.Devices is

   package US renames Ada.Strings.Unbounded;

   subtype Word is Interfaces.Unsigned_64;

   --  Which input a fault is in.
   type Input is (Svd_Input, Policy_Input);

   --  What kind of fault, each its own diagnostic code (D558).
   type Fault_Kind is
     (No_Fault,
      --  The SVD is not well-formed XML in the subset Landin.Xml reads.
      Malformed_Svd,
      --  The policy is not JSON, or not a policy: a member missing, of the
      --  wrong shape, or unknown.
      Invalid_Policy,
      --  The SVD is not the one the policy names: its SHA-256, device name
      --  or version differs.
      Input_Mismatch,
      --  The SVD uses a form the importer does not read for a selected
      --  register: an array, a cluster, a derived register or field, or an
      --  enumerated value it cannot represent.
      Unsupported_Form,
      --  What the SVD says cannot be generated as it says it: overlapping
      --  fields, a width other than 32, a collision between two names once
      --  normalized, a missing property, or an encoding outside its field.
      Inconsistent_Device,
      --  The policy selects or names something the SVD does not have.
      Not_In_Svd);

   type Fault is record
      Kind : Fault_Kind := No_Fault;
      Within : Input := Svd_Input;
      --  A zero-based byte offset into that input, where there is one to
      --  point at.
      Offset : Natural := 0;
      Has_Offset : Boolean := False;
      Message : US.Unbounded_String;
   end record;

   No_Problem : constant Fault := (others => <>);

   --  One file made, its path relative to the output directory and its
   --  bytes.
   type Output is record
      Path : US.Unbounded_String;
      Content : US.Unbounded_String;
   end record;

   package Output_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Output);

   --  An SVD scaledNonNegativeInteger as the importer reads one: decimal,
   --  `0x` or `0X` hexadecimal, or `#` binary, after surrounding space is
   --  removed.  A multiplier suffix is not read.
   function Is_Number (Text : String) return Boolean;

   function Number (Text : String) return Word
     with Pre => Is_Number (Text);

   --  Text without the space XML admits around it.
   function Trimmed (Text : String) return String;

   --  A vendor's identifier the importer spells as Landin: an ASCII letter
   --  and then letters, digits and underscores.
   function Is_Vendor_Name (Text : String) return Boolean;

   --  Lowercase ASCII.
   function Lowered (Text : String) return String;

   --  Whether a lowercased name is one Landin lets no module declare and
   --  no import name: a keyword, or one of the toolchain's namespaces.  A
   --  name the importer writes with nothing added must not be one, or the
   --  module it writes cannot be compiled or imported.
   function Is_Reserved (Name : String) return Boolean;

   --  `0x` and eight lowercase digits; `0x` and as few as the value needs.
   function Hex8 (Value : Word) return String;

   function Hex (Value : Word) return String;

   --  A natural number in decimal without a sign or separators.
   function Decimal (Value : Word) return String;

   --  A path a policy may give an output: relative, its parts nonempty and
   --  none of them `.` or `..`, with no backslash.
   function Is_Relative_Path (Text : String) return Boolean;

end Landin.Devices;
