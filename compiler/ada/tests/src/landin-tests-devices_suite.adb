--  `refine svd`: an SVD and its policy, projected onto Landin (D555-D558).
--
--  A toy device written here exercises every form the importer reads --
--  peripheral derivation, device-level property inheritance, an alternate
--  register, the three ways a field says where it lies, enumerated and
--  plain fields, access left to fields -- and the generated text is held
--  line by line.  Each form it does not read is refused by name, each
--  policy fault is named, and the command's replacement is driven through
--  the fake filesystem: written whole, left alone when unchanged, stale
--  files removed, and nothing replaced when anything is in the way.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;

with Landin.Commands;
with Landin.Devices;
with Landin.Devices.Projection;
with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;
with Landin.Xml;

package body Landin.Tests.Devices_Suite is

   package US renames Ada.Strings.Unbounded;
   package Dev renames Landin.Devices;

   use type Dev.Fault_Kind;

   LF : constant Character := ASCII.LF;

   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) /= 0);

   function Replaced (Text, Old, New_Text : String) return String;

   function Replaced (Text, Old, New_Text : String) return String is
      At_Index : constant Natural := Ada.Strings.Fixed.Index (Text, Old);
   begin
      if At_Index = 0 then
         raise Landin.Compiler_Defect with "the test's anchor is absent: "
           & Old;
      end if;
      return Text (Text'First .. At_Index - 1) & New_Text
        & Text (At_Index + Old'Length .. Text'Last);
   end Replaced;

   Svd : constant String :=
     "<?xml version=""1.0"" encoding=""utf-8""?>" & LF
     & "<device schemaVersion=""1.1"">" & LF
     & "  <name>TOY1</name>" & LF
     & "  <vendor>Example</vendor>" & LF
     & "  <version>1.0</version>" & LF
     & "  <licenseText>Copyright the vendor.&#10;" & LF
     & "    SPDX-License-Identifier: Apache-2.0</licenseText>" & LF
     & "  <cpu><name>CM7</name>"
     & "<deviceNumInterrupts>4</deviceNumInterrupts></cpu>" & LF
     & "  <size>32</size>" & LF
     & "  <resetValue>0x0</resetValue>" & LF
     & "  <resetMask>0xFFFFFFFF</resetMask>" & LF
     & "  <peripherals>" & LF
     & "    <peripheral>" & LF
     & "      <name>UARTA</name>" & LF
     & "      <baseAddress>0x40001000</baseAddress>" & LF
     & "      <interrupt><name>UARTA_IRQ</name><value>2</value></interrupt>"
     & LF
     & "      <registers>" & LF
     & "        <register>" & LF
     & "          <name>CR</name>" & LF
     & "          <addressOffset>0x4</addressOffset>" & LF
     & "          <access>read-write</access>" & LF
     & "          <resetValue>0x00000005</resetValue>" & LF
     & "          <fields>" & LF
     & "            <field><name>MODE</name><bitOffset>1</bitOffset>"
     & "<bitWidth>2</bitWidth>" & LF
     & "              <enumeratedValues>" & LF
     & "                <enumeratedValue><name>OFF</name><value>0</value>"
     & "</enumeratedValue>" & LF
     & "                <enumeratedValue><name>FAST</name><value>#10</value>"
     & "</enumeratedValue>" & LF
     & "              </enumeratedValues></field>" & LF
     & "            <field><name>EN</name><bitRange>[0:0]</bitRange>"
     & "<modifiedWriteValues>oneToClear</modifiedWriteValues></field>" & LF
     & "          </fields>" & LF
     & "        </register>" & LF
     & "        <register>" & LF
     & "          <name>CR_IN</name>" & LF
     & "          <alternateRegister>CR</alternateRegister>" & LF
     & "          <addressOffset>0x4</addressOffset>" & LF
     & "          <fields><field><name>LEVEL</name><lsb>8</lsb><msb>15</msb>"
     & "<access>read-only</access></field></fields>" & LF
     & "        </register>" & LF
     & "      </registers>" & LF
     & "    </peripheral>" & LF
     & "    <peripheral derivedFrom=""UARTA"">" & LF
     & "      <name>UARTB</name>" & LF
     & "      <baseAddress>0x40002000</baseAddress>" & LF
     & "      <interrupt><name>UARTB_IRQ</name><value>3</value></interrupt>"
     & LF
     & "      <interrupt><name>UARTA_IRQ</name><value>2</value></interrupt>"
     & LF
     & "    </peripheral>" & LF
     & "  </peripherals>" & LF
     & "</device>" & LF;

   function Policy_For (Text : String; Rest : String := "") return String
   is ("{""schema"": 2, ""device"": ""TOY1"", ""svd_version"": ""1.0"","
       & " ""svd_sha256"": """ & GNAT.SHA256.Digest (Text) & ""","
       & " ""notice"": [""Toy notice.""],"
       & " ""selection"": {""UARTA"": [""CR"", ""CR_IN""],"
       & " ""UARTB"": [""CR""]},"
       & " ""policies"": {"
       & """UARTA.CR"": {""read"": ""normal"", ""write"": ""one_clears"","
       & " ""reserved"": ""zero"", ""write_mask"": ""0x00000001""},"
       & """UARTA.CR_IN"": {""read"": ""normal"", ""write"": ""refused"","
       & " ""reserved"": ""zero""},"
       & """UARTB.CR"": {""read"": ""modify"", ""write"": ""normal"","
       & " ""reserved"": ""preserve""}}"
       & Rest & "}");

   function Output_Of (Made : Dev.Projection.Result; Path : String)
     return String;

   function Output_Of (Made : Dev.Projection.Result; Path : String)
     return String is
   begin
      for Item of Made.Outputs loop
         if US.To_String (Item.Path) = Path then
            return US.To_String (Item.Content);
         end if;
      end loop;
      return "absent: " & Path;
   end Output_Of;

   procedure A_Device_Becomes_Modules (Item : in out Landin.Testing.Context);

   procedure A_Device_Becomes_Modules (Item : in out Landin.Testing.Context)
   is
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
   begin
      Dev.Projection.Project (Svd, Policy_For (Svd), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault,
         "the toy is projected: " & US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      Landin.Testing.Check_Equal
        (Item, Natural (Made.Outputs.Length), 5,
         "two modules, the correspondence, the manifest and interrupts");
      declare
         A : constant String := Output_Of (Made, "toy1/uarta/device.ldn");
         B : constant String := Output_Of (Made, "toy1/uartb/device.ldn");
      begin
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (A, "-- Toy notice." & LF
               & "-- Reset metadata performs no initialization. No device"
               & " RMW is implicit." & LF) = A'First,
            "the notice heads the module");
         for Expected of Landin.Platform.Path_List'
           ["public base: usize = 0x40001000" & LF & LF,
            "public cr_mode_off: atom" & LF & "public cr_mode_fast: atom" & LF
            & "public cr_mode_value: type = u2 (cr_mode_off = 0 |"
            & " cr_mode_fast = 2)" & LF,
            "public cr_offset: usize = 0x4" & LF
            & "public cr_address: usize = 0x40001004" & LF
            & "public cr_named_mask: u32 = 0x00000007" & LF
            & "public cr_reset_mask: u32 = 0x00000007" & LF
            & "public cr_reset_value: u32 = 0x00000005" & LF
            & "public cr_image: type = layout(packed, u32) struct" & LF
            & "    f_mode: cr_mode_value at 1..2" & LF
            & "    f_en: u1 at 0..0" & LF & "end cr_image" & LF,
            "    compiler.register_write(port, raw, compiler.one_clears," & LF
            & "                            compiler.write_zero, 0x00000001)",
            "public cr_in_reset_mask: u32 = 0x0000ff00" & LF,
            "    f_level: u8 at 8..15" & LF,
            "public cr_in_read: (device_base: usize) -> (raw: u32) =" & LF
            & "    port: ptr u32 = ptr(device_base + cr_in_offset)" & LF
            & "    raw = compiler.register_read(port, compiler.normal_read)"]
         loop
            Landin.Testing.Check
              (Item, Contains (A, Expected), "UARTA has: " & Expected);
         end loop;
         Landin.Testing.Check
           (Item, not Contains (A, "cr_in_write"),
            "a refused write has no accessor");
         Landin.Testing.Check
           (Item, A (A'Last) = LF and then A (A'Last - 1) /= LF,
            "the module ends with one line end");
         for Expected of Landin.Platform.Path_List'
           ["public base: usize = 0x40002000",
            "public cr_address: usize = 0x40002004",
            "    raw = compiler.volatile_load(port)",
            "                            compiler.preserve, 0x00000007)"]
         loop
            Landin.Testing.Check
              (Item, Contains (B, Expected), "UARTB has: " & Expected);
         end loop;
      end;
      declare
         Rows : constant String :=
           Output_Of (Made, "toy1/correspondence.json");
      begin
         for Expected of Landin.Platform.Path_List'
           ["[" & LF & "  {" & LF & "    ""address"": 1073745924," & LF
            & "    ""alignment"": 4," & LF & "    ""derived_from"": null,"
            & LF & "    ""fields"": [" & LF & "      {" & LF
            & "        ""access"": ""read-write""," & LF
            & "        ""encodings"": [" & LF & "          [" & LF
            & "            ""OFF""," & LF & "            0" & LF
            & "          ],",
            """alternate_register"": ""CR"",",
            """modified_write"": ""oneToClear"",",
            """register_access"": null,",
            """derived_from"": ""UARTA"",",
            """write_mask"": ""0x00000001""" & LF,
            """source"": ""UARTB.CR"","]
         loop
            Landin.Testing.Check
              (Item, Contains (Rows, Expected),
               "the correspondence has: " & Expected);
         end loop;
         Landin.Testing.Check
           (Item, Rows (Rows'Last - 2 .. Rows'Last) = LF & "]" & LF,
            "the correspondence is one indented list");
         Landin.Testing.Check_Equal
           (Item, Output_Of (Made, "toy1/outputs.json"),
            "{" & LF & "  ""toy1/correspondence.json"": """
            & GNAT.SHA256.Digest (Rows) & """," & LF
            & "  ""toy1/uarta/device.ldn"": """
            & GNAT.SHA256.Digest (Output_Of (Made, "toy1/uarta/device.ldn"))
            & """," & LF
            & "  ""toy1/uartb/device.ldn"": """
            & GNAT.SHA256.Digest (Output_Of (Made, "toy1/uartb/device.ldn"))
            & """" & LF & "}" & LF,
            "the manifest hashes each file, sorted");
      end;
      Landin.Testing.Check_Equal
        (Item, Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
         "-- Interrupts of the TOY1, from its SVD: vendor Example, version"
         & " 1.0." & LF
         & "-- SVD SHA-256 " & GNAT.SHA256.Digest (Svd) & "." & LF
         & "-- Copyright the vendor." & LF
         & "-- SPDX-License-Identifier: Apache-2.0" & LF
         & "-- Generated from the SVD; memory.ldn beside it is written by"
         & " hand." & LF & LF
         & "compiler.device(""toy1"")" & LF
         & "compiler.core(""cortex-m7"")" & LF
         & "compiler.vectors(20)" & LF
         & "compiler.interrupt(""UARTA_IRQ"", 2)" & LF
         & "compiler.interrupt(""UARTB_IRQ"", 3)" & LF,
         "D542's generated half, each pair once and in order");
   end A_Device_Becomes_Modules;

   procedure Every_Refusal_Is_Named (Item : in out Landin.Testing.Context);

   procedure Every_Refusal_Is_Named (Item : in out Landin.Testing.Context) is
      procedure Expect
        (Text : String; Kind : Dev.Fault_Kind; Words : String;
         Line : Natural := 0; Policy : String := "");

      procedure Expect
        (Text : String; Kind : Dev.Fault_Kind; Words : String;
         Line : Natural := 0; Policy : String := "")
      is
         Made : Dev.Projection.Result;
         Problem : Dev.Fault;
         Document : Landin.Xml.Document;
      begin
         Dev.Projection.Project
           (Text, (if Policy = "" then Policy_For (Text) else Policy),
            Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Kind
            and then Contains (US.To_String (Problem.Message), Words)
            and then Made.Outputs.Is_Empty,
            Dev.Fault_Kind'Image (Kind) & " " & Words & ", not "
            & Dev.Fault_Kind'Image (Problem.Kind) & " "
            & US.To_String (Problem.Message));
         if Line /= 0 then
            Landin.Xml.Parse (Document, Text);
            Landin.Testing.Check_Equal
              (Item, Landin.Xml.Line_Of (Document, Problem.Offset), Line,
               "where: " & Words);
         end if;
      end Expect;
   begin
      Expect (Replaced (Svd, "<name>CR</name>", "<name>CR</name><dim>2</dim>"),
              Dev.Unsupported_Form, "an array", 19);
      Expect (Replaced (Svd, "<size>32</size>", "<size>16</size>"),
              Dev.Unsupported_Form, "16 bits wide", 9);
      Expect (Replaced
                (Replaced (Svd, "<register>" & LF
                                & "          <name>CR</name>",
                           "<cluster><name>K</name><register>" & LF
                           & "          <name>CR</name>"),
                 "</register>" & LF & "        <register>",
                 "</register></cluster>" & LF & "        <register>"),
              Dev.Unsupported_Form, "in a cluster");
      Expect (Replaced (Svd, "<register>" & LF & "          <name>CR</name>",
                        "<register derivedFrom=""CR_IN"">" & LF
                        & "          <name>CR</name>"),
              Dev.Unsupported_Form, "derived from another", 18);
      Expect (Replaced (Svd, "<name>CR</name>",
                        "<name>CR</name><alternateGroup>G</alternateGroup>"),
              Dev.Unsupported_Form, "alternateGroup");
      Expect (Replaced (Svd, "<field><name>EN</name>",
                        "<field derivedFrom=""MODE""><name>EN</name>"),
              Dev.Unsupported_Form, "a field derived");
      Expect (Replaced (Svd, "<enumeratedValue><name>OFF</name>",
                        "<enumeratedValue><isDefault>true</isDefault>"
                        & "<name>OFF</name>"),
              Dev.Unsupported_Form, "default enumerated value");
      Expect (Replaced (Svd, "<value>#10</value>", "<value>#1x</value>"),
              Dev.Unsupported_Form, "not a number");
      Expect (Replaced (Svd, "<name>UARTB</name>",
                        "<name>UARTB</name><registers/>"),
              Dev.Unsupported_Form, "registers of its own");
      Expect (Replaced (Svd, "<peripheral>" & LF & "      <name>UARTA</name>",
                        "<peripheral derivedFrom=""UARTB"">" & LF
                        & "      <name>UARTA</name>"),
              Dev.Unsupported_Form, "itself derived");
      Expect (Replaced (Svd, "<name>CM7</name>", "<name>CA53</name>"),
              Dev.Unsupported_Form, "none of CM0");
      Expect (Replaced (Svd, "<bitRange>[0:0]</bitRange>",
                        "<bitRange>[1:0]</bitRange>"),
              Dev.Inconsistent_Device, "overlaps", 29);
      Expect (Replaced (Svd, "<value>#10</value>", "<value>4</value>"),
              Dev.Inconsistent_Device, "does not fit");
      Expect (Replaced (Svd, "<value>#10</value>", "<value>0</value>"),
              Dev.Inconsistent_Device, "encodes 0 twice");
      Expect (Replaced (Svd, "<name>EN</name>", "<name>Mode</name>"),
              Dev.Inconsistent_Device, "both f_mode");
      Expect (Replaced (Svd, "<addressOffset>0x4</addressOffset>" & LF
                        & "          <fields><field><name>LEVEL",
                        "<addressOffset>0x8</addressOffset>" & LF
                        & "          <fields><field><name>LEVEL"),
              Dev.Inconsistent_Device, "at another address");
      Expect (Replaced (Svd, "<addressOffset>0x4</addressOffset>" & LF
                        & "          <access>",
                        "<addressOffset>0x6</addressOffset>" & LF
                        & "          <access>"),
              Dev.Inconsistent_Device, "word-aligned");
      Expect (Replaced (Svd, "<access>read-only</access>", ""),
              Dev.Inconsistent_Device, "no access");
      Expect (Replaced (Svd, "</device>", "</devices>"),
              Dev.Malformed_Svd, "does not close", 47);
      Expect (Svd, Dev.Input_Mismatch, "reviewed against",
              Policy => Policy_For (Svd & " "));
      Expect (Replaced (Svd, "<version>1.0</version>",
                        "<version>1.1</version>"),
              Dev.Input_Mismatch, "version 1.1");
      Expect (Svd, Dev.Not_In_Svd, "UARTC",
              Policy => Replaced
                (Replaced (Policy_For (Svd), """UARTB"": [""CR""]",
                           """UARTC"": [""CR""]"),
                 """UARTB.CR""", """UARTC.CR"""));
      Expect (Svd, Dev.Invalid_Policy, "not JSON", Policy => "{");
      Expect (Svd, Dev.Invalid_Policy, "schema is not 2",
              Policy => Replaced (Policy_For (Svd), """schema"": 2",
                                  """schema"": 1"));
      Expect (Svd, Dev.Invalid_Policy, """extra"" is not one",
              Policy => Policy_For (Svd, ", ""extra"": 1"));
      Expect (Svd, Dev.Invalid_Policy, "not normal, modify or refused",
              Policy => Replaced (Policy_For (Svd), """read"": ""modify""",
                                  """read"": ""clears"""));
      Expect (Svd, Dev.Invalid_Policy, "has no policy",
              Policy => Replaced (Policy_For (Svd), """UARTA"": [""CR"",",
                                  """UARTA"": [""CR"", ""CR2"","));
      Expect (Svd, Dev.Invalid_Policy, "outside the register's named",
              Policy => Replaced (Policy_For (Svd), "0x00000001",
                                  "0x00000100"));
      Expect (Svd, Dev.Invalid_Policy, "not a relative path",
              Policy => Policy_For (Svd, ", ""prefix"": ""../up"""));
      Expect (Svd, Dev.Not_In_Svd, "removes an interrupt the SVD",
              Policy => Policy_For
                (Svd, ", ""interrupt_corrections"": {""NOWHERE"": {""omit"":"
                 & " true, ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "which the SVD gives UARTA_IRQ",
              Policy => Policy_For
                (Svd, ", ""interrupt_corrections"": {""NEW_IRQ"": {""value"":"
                 & " 2, ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "the value the SVD already gives",
              Policy => Policy_For
                (Svd, ", ""interrupt_corrections"": {""UARTA_IRQ"":"
                 & " {""value"": 2, ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "where its reviewer read it",
              Policy => Policy_For
                (Svd, ", ""reset_corrections"": {""UARTA.CR"":"
                 & " {""value"": ""0x00000001"", ""source"": """"}}"));
   end Every_Refusal_Is_Named;

   procedure A_Correction_Is_Recorded (Item : in out Landin.Testing.Context);

   procedure A_Correction_Is_Recorded (Item : in out Landin.Testing.Context)
   is
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
   begin
      Dev.Projection.Project
        (Svd, Policy_For
           (Svd, ", ""reset_corrections"": {""UARTB.CR"": {""value"":"
            & " ""0x00000003"", ""source"": ""the manual, 1.2""}},"
            & " ""numeric_enums"": [""UARTA.CR.MODE""],"
            & " ""reset_mask_overrides"": {""UARTA.CR"": ""0x00000001""}"),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault, US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/uartb/device.ldn"),
                         "public cr_reset_value: u32 = 0x00000003"),
         "the corrected reset value is generated");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/correspondence.json"),
                         """reset_correction"": {" & LF
                         & "      ""source"": ""the manual, 1.2""," & LF
                         & "      ""value"": 3" & LF & "    },"),
         "and recorded beside the SVD's");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                         "    f_mode: u2 at 1..2")
         and then not Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                                "cr_mode_off"),
         "a numeric enumeration is a plain field");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                         "public cr_reset_mask: u32 = 0x00000001"),
         "an overridden reset mask");
      Dev.Projection.Project
        (Svd, Policy_For
           (Svd, ", ""interrupt_corrections"": {""EXTRA_IRQ"": {""value"": 9,"
            & " ""source"": ""the manual, p. 3""}, ""UARTB_IRQ"": {""value"":"
            & " 1, ""source"": ""the manual, p. 4""}, ""UARTA_IRQ"":"
            & " {""omit"": true, ""source"": ""the manual, p. 5""}}"),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault, US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      Landin.Testing.Check_Equal
        (Item, Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
         "-- Interrupts of the TOY1, from its SVD: vendor Example, version"
         & " 1.0." & LF
         & "-- SVD SHA-256 " & GNAT.SHA256.Digest (Svd) & "." & LF
         & "-- Copyright the vendor." & LF
         & "-- SPDX-License-Identifier: Apache-2.0" & LF
         & "-- Generated from the SVD; memory.ldn beside it is written by"
         & " hand." & LF
         & "-- The policy adds EXTRA_IRQ at 9: the manual, p. 3." & LF
         & "-- The policy moves UARTB_IRQ from 3 to 1: the manual, p. 4." & LF
         & "-- The policy removes UARTA_IRQ at 2: the manual, p. 5." & LF
         & LF
         & "compiler.device(""toy1"")" & LF
         & "compiler.core(""cortex-m7"")" & LF
         & "compiler.vectors(26)" & LF
         & "compiler.interrupt(""UARTB_IRQ"", 1)" & LF
         & "compiler.interrupt(""EXTRA_IRQ"", 9)" & LF,
         "D542's text with the policy's interrupt corrections, each said");
   end A_Correction_Is_Recorded;

   function Content_Of
     (Host : Landin.Testing.Fakes.Fake_Filesystem; Path : String)
      return String;

   function Content_Of
     (Host : Landin.Testing.Fakes.Fake_Filesystem; Path : String)
      return String
   is
      Text : US.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      use type Landin.Platform.Read_Status;
   begin
      Host.Read_File (Path, Text, Status);
      return (if Status = Landin.Platform.Read_Ok then US.To_String (Text)
              else "");
   end Content_Of;

   procedure Outputs_Are_Replaced_Whole
     (Item : in out Landin.Testing.Context);

   procedure Outputs_Are_Replaced_Whole
     (Item : in out Landin.Testing.Context)
   is
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      Arguments : constant Landin.Platform.Path_List :=
        ["svd", "--policy=toy.json", "--out-dir=out", "toy.svd"];

      procedure Prepare (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

      procedure Prepare (Host : in out Landin.Testing.Fakes.Fake_Filesystem)
      is
      begin
         Host.Add_File ("toy.svd", Svd);
         Host.Add_File ("toy.json", Policy_For (Svd));
         Host.Add_Directory ("out");
      end Prepare;

      function Code_Of (Result : Landin.Driver.Outcome) return String is
        (US.To_String (Result.Report));
   begin
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
      begin
         Prepare (Host);
         declare
            First : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (Arguments, Host, Tools, Meter);
         begin
            Landin.Testing.Check_Equal
              (Item, First.Status, 0, "written: " & Code_Of (First));
            Landin.Testing.Check
              (Item, Contains (US.To_String (First.Output),
                               "5 files under out, 5 of them written"),
               "says what it wrote: " & US.To_String (First.Output));
            Landin.Testing.Check
              (Item, Contains (Content_Of (Host, "out/toy1/uarta/device.ldn"),
                               "public cr_offset")
               and then Contains
                 (Content_Of (Host, "out/descriptions/toy1/interrupts.ldn"),
                  "compiler.vectors(20)"),
               "the modules and the description are in place");
            Landin.Testing.Check
              (Item, not Host.Exists ("out/toy1/uarta/device.ldn.refine-new")
               and then not Host.Exists
                 ("out/toy1/uarta/device.ldn.refine-old"),
               "nothing staged or kept is left");
         end;
         declare
            Again : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (Arguments, Host, Tools, Meter);
         begin
            Landin.Testing.Check
              (Item, Again.Status = 0
               and then Contains (US.To_String (Again.Output),
                                  "0 of them written"),
               "an unchanged file is left alone");
         end;
         Host.Add_File
           ("toy.json",
            Replaced (Replaced (Policy_For (Svd), ", ""UARTB"": [""CR""]",
                                ""),
                      "}," & """UARTB.CR"": {""read"": ""modify"","
                      & " ""write"": ""normal"", ""reserved"": ""preserve""}}",
                      "}}"));
         declare
            Narrowed : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (Arguments, Host, Tools, Meter);
         begin
            Landin.Testing.Check
              (Item, Narrowed.Status = 0
               and then Contains (US.To_String (Narrowed.Output),
                                  "1 no longer made removed")
               and then not Host.Exists ("out/toy1/uartb/device.ldn"),
               "a file the old manifest named is removed: "
               & Code_Of (Narrowed));
         end;
      end;
      declare
         procedure Refused
           (Arrange : access procedure
              (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
            Code, Words : String);

         procedure Refused
           (Arrange : access procedure
              (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
            Code, Words : String)
         is
            Host : Landin.Testing.Fakes.Fake_Filesystem;
         begin
            Prepare (Host);
            Arrange (Host);
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Commands.Execute (Arguments, Host, Tools, Meter);
            begin
               Landin.Testing.Check
                 (Item, Result.Status = Landin.Driver.Status_Reported
                  and then Contains (Code_Of (Result), "error[" & Code & "]")
                  and then Contains (Code_Of (Result), Words)
                  and then not Host.Exists ("out/toy1/uarta/device.ldn")
                  and then not Host.Exists
                    ("out/toy1/uarta/device.ldn.refine-new"),
                  Code & " " & Words & ": " & Code_Of (Result));
            end;
         end Refused;

         procedure Leftover
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Leftover
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/toy1/outputs.json.refine-old", "");
         end Leftover;

         procedure Directory_In_The_Way
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Directory_In_The_Way
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_Directory ("out/toy1/correspondence.json");
         end Directory_In_The_Way;

         procedure No_Output_Directory
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure No_Output_Directory
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out", "");
         end No_Output_Directory;

         procedure Unwritable
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Unwritable
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Refuse_Writes;
         end Unwritable;

         procedure Foreign_Manifest
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Foreign_Manifest
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/toy1/outputs.json",
                           "{""../../escape"": ""0""}");
         end Foreign_Manifest;

         procedure No_Svd
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure No_Svd
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_Unreadable ("toy.svd");
         end No_Svd;
      begin
         Refused (Leftover'Access, "L0531", "interrupted run");
         Refused (Directory_In_The_Way'Access, "L0531", "is a directory");
         Refused (No_Output_Directory'Access, "L0531", "not a directory");
         Refused (Unwritable'Access, "L0005", "nothing was replaced");
         Refused (Foreign_Manifest'Access, "L0531", "not a path below it");
         Refused (No_Svd'Access, "L0003", "cannot read the SVD");
      end;
   end Outputs_Are_Replaced_Whole;

   procedure Each_Fault_Has_Its_Code (Item : in out Landin.Testing.Context);

   procedure Each_Fault_Has_Its_Code (Item : in out Landin.Testing.Context)
   is
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;

      procedure Expect (Text, Policy, Code, Place : String);

      procedure Expect (Text, Policy, Code, Place : String) is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
      begin
         Host.Add_File ("toy.svd", Text);
         Host.Add_File ("toy.json", Policy);
         Host.Add_Directory ("out");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute
                (["svd", "--policy=toy.json", "--out-dir=out", "toy.svd"],
                 Host, Tools, Meter);
            Report : constant String := US.To_String (Result.Report);
         begin
            Landin.Testing.Check
              (Item, Result.Status = Landin.Driver.Status_Reported
               and then Contains (Report, "error[" & Code & "]")
               and then Contains (Report, "--> " & Place),
               Code & " at " & Place & ": " & Report);
         end;
      end Expect;

      Malformed : constant String := Replaced (Svd, "</device>", "</dev>");
      Arrayed : constant String :=
        Replaced (Svd, "<name>CR</name>", "<name>CR</name><dim>2</dim>");
      Overlapping : constant String :=
        Replaced (Svd, "<bitRange>[0:0]</bitRange>",
                  "<bitRange>[1:0]</bitRange>");
   begin
      Expect (Malformed, Policy_For (Malformed), "L0525", "toy.svd:47:1");
      Expect (Svd, "{", "L0526", "toy.json:1:2");
      Expect (Svd, Policy_For (Malformed), "L0527", "toy.svd:1:1");
      Expect (Arrayed, Policy_For (Arrayed), "L0528", "toy.svd:19:");
      Expect (Overlapping, Policy_For (Overlapping), "L0529", "toy.svd:29:");
      Expect (Svd, Replaced
                (Replaced (Policy_For (Svd), """UARTB"": [""CR""]",
                           """UARTC"": [""CR""]"),
                 """UARTB.CR""", """UARTC.CR"""), "L0530", "toy.svd:");
   end Each_Fault_Has_Its_Code;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "devices", "a device becomes modules",
         A_Device_Becomes_Modules'Access);
      Landin.Testing.Register
        (Into, "devices", "every refusal is named",
         Every_Refusal_Is_Named'Access);
      Landin.Testing.Register
        (Into, "devices", "a correction is recorded",
         A_Correction_Is_Recorded'Access);
      Landin.Testing.Register
        (Into, "devices", "outputs are replaced whole",
         Outputs_Are_Replaced_Whole'Access);
      Landin.Testing.Register
        (Into, "devices", "each fault has its code",
         Each_Fault_Has_Its_Code'Access);
   end Register;

end Landin.Tests.Devices_Suite;
