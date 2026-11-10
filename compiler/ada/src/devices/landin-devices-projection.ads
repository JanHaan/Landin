--  An SVD and its policy, projected onto Landin (D555-D557).
--
--  The projection reads the policy, requires the SVD to be the one the
--  policy names, reads the SVD with Landin.Xml, resolves each selected
--  register's properties through the SVD's inheritance -- the register,
--  its peripheral, the peripheral it is derived from, the device -- and
--  writes:
--
--  * one module per selected peripheral, `PREFIX/NAME/device.ldn`, of
--    packed register images, their encodings, and the accessors the
--    register's policy admits, each one 32-bit transaction;
--  * the correspondence, every selected register and field as the SVD gave
--    it beside what was generated from it, as indented JSON with sorted
--    keys;
--  * the manifest, the SHA-256 of each of those files, which is also how
--    the command knows which files are its own;
--  * interrupts.ldn, the generated half of the device's description, in
--    D542's exact text.
--
--  What it does not read for a selected register it refuses, naming the
--  element: arrays, clusters, derived registers and fields, alternate
--  groups, and enumerated values that are defaults or carry don't-care
--  bits.  An alternate register is read as a register of its own at the
--  address it shares, and recorded as an alternate.

package Landin.Devices.Projection is

   type Result is record
      --  Every file, its path relative to the output directory, in the
      --  order written: the modules, the correspondence, the manifest and
      --  interrupts.ldn.
      Outputs : Output_Vectors.Vector;
      --  The import root the modules are under, relative to the output
      --  directory, which the manifest's paths are relative to.
      Modules : US.Unbounded_String;
      --  The manifest's path relative to the output directory.
      Manifest : US.Unbounded_String;
   end record;

   procedure Project
     (Svd_Text, Policy_Text : String;
      Made : out Result;
      Problem : out Fault);

   --  A path under Modules, as relative to the output directory.
   function Under (Directory, Path : String) return String;

   --  The SHA-256 of Text in lowercase hexadecimal, as the manifest
   --  records each file it lists.
   function Sha256 (Text : String) return String;

end Landin.Devices.Projection;
