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

with Ada.Execution_Time;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;

with Landin.Commands;
with Landin.Devices;
with Landin.Devices.Projection;
with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;
with Landin.Targets.Firmware;
with Landin.Xml;

package body Landin.Tests.Devices_Suite is

   package US renames Ada.Strings.Unbounded;
   package Dev renames Landin.Devices;

   use type Dev.Fault_Kind;
   use type Dev.Input;

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
      --  D635: an SVD's CM33 is a description's cortex-m33.
      declare
         M33 : constant String :=
           Replaced (Svd, "<name>CM7</name>", "<name>CM33</name>");
      begin
         Dev.Projection.Project (M33, Policy_For (M33), Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.No_Fault
              and then Contains
                (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
                 LF & "compiler.core(""cortex-m33"")" & LF),
            "a CM33 is a cortex-m33: " & US.To_String (Problem.Message));
      end;
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
      --  D700: a RISC-V SVD's cpu says nothing of its interrupts.
      Expect (Replaced (Svd, "<name>CM7</name>", "<name>RV32IMC</name>"),
              Dev.Unsupported_Form, "a RISC-V device's policy names its"
              & " core");
      Expect (Svd, Dev.Invalid_Policy, "not hazard3, esp-rv32imc,",
              Policy => Policy_For (Svd, ", ""core"": ""sifive-e31"""));
      Expect (Svd, Dev.Invalid_Policy, "which D542 does not admit",
              Policy => Policy_For (Svd, ", ""identity"": ""Toy_1"""));
      Expect (Replaced (Svd, "<name>TOY1</name>", "<name>TOY 1</name>"),
              Dev.Invalid_Policy, "not a vendor name",
              Policy => Replaced (Policy_For (Svd), """device"": ""TOY1""",
                                  """device"": ""TOY 1"""));
      --  D704: an offset correction says another offset, aligned, with
      --  its source.
      Expect (Svd, Dev.Invalid_Policy, "the offset the SVD already gives",
              Policy => Policy_For
                (Svd, ", ""register_corrections"": {""UARTB.CR"":"
                 & " {""offset"": ""0x00000004"", ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "not a multiple of four",
              Policy => Policy_For
                (Svd, ", ""register_corrections"": {""UARTB.CR"":"
                 & " {""offset"": ""0x00000006"", ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "names no selected register",
              Policy => Policy_For
                (Svd, ", ""register_corrections"": {""UARTB.CR_IN"":"
                 & " {""offset"": ""0x00000008"", ""source"": ""p. 1""}}"));
      --  D705: an addition is of what the SVD lacks, in its own words.
      Expect (Svd, Dev.Invalid_Policy, "adds a peripheral the SVD gives",
              Policy => Policy_For
                (Svd, ", ""peripheral_additions"": {""UARTA"": {""base"":"
                 & " ""0x40001000"", ""source"": ""p. 1"", ""registers"":"
                 & " {""X"": {""offset"": ""0x0"", ""access"":"
                 & " ""read-write"", ""reset"": ""0x0"", ""fields"":"
                 & " {""A"": {""bits"": ""[0:0]""}}}}}}"));
      Expect (Svd, Dev.Invalid_Policy, "an array exactly when its name",
              Policy => Policy_For
                (Svd, ", ""peripheral_additions"": {""NEW"": {""base"":"
                 & " ""0x50000000"", ""source"": ""p. 1"", ""registers"":"
                 & " {""X%s"": {""offset"": ""0x0"", ""access"":"
                 & " ""read-write"", ""reset"": ""0x0"", ""fields"":"
                 & " {""A"": {""bits"": ""[0:0]""}}}}}}"));
      Expect (Svd, Dev.Invalid_Policy, "not [HIGH:LOW] in decimal",
              Policy => Policy_For
                (Svd, ", ""peripheral_additions"": {""NEW"": {""base"":"
                 & " ""0x50000000"", ""source"": ""p. 1"", ""registers"":"
                 & " {""X"": {""offset"": ""0x0"", ""access"":"
                 & " ""read-write"", ""reset"": ""0x0"", ""fields"":"
                 & " {""A"": {""bits"": ""[0x1:0]""}}}}}}"));
      Expect (Svd, Dev.Invalid_Policy, "where its reviewer read it",
              Policy => Policy_For
                (Svd, ", ""peripheral_additions"": {""NEW"": {""base"":"
                 & " ""0x50000000"", ""source"": """", ""registers"": {}}}"));
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
      --  D652: a field a correction adds is one the SVD lacks, beside
      --  every field the SVD gives, with an access the SVD's words say.
      Expect (Svd, Dev.Invalid_Policy, "adds a field the SVD gives",
              Policy => Policy_For
                (Svd, ", ""field_corrections"": {""UARTA.CR.EN"": {""add"":"
                 & " true, ""bits"": ""[0:0]"", ""access"": ""read-write"","
                 & " ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "overlaps another",
              Policy => Policy_For
                (Svd, ", ""field_corrections"": {""UARTA.CR.WIDE"": {""add"":"
                 & " true, ""bits"": ""[3:2]"", ""access"": ""read-write"","
                 & " ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "not one of the SVD's",
              Policy => Policy_For
                (Svd, ", ""field_corrections"": {""UARTA.CR.NEW"": {""add"":"
                 & " true, ""bits"": ""[4:4]"", ""access"": ""rw"","
                 & " ""source"": ""p. 1""}}"));
      Expect (Svd, Dev.Invalid_Policy, "only a field it adds says",
              Policy => Policy_For
                (Svd, ", ""field_corrections"": {""UARTA.CR.EN"": {""bits"":"
                 & " ""[0:0]"", ""access"": ""read-write"","
                 & " ""source"": ""p. 1""}}"));
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
      --  D652: a field the SVD lacks, added by a reviewed correction.
      Dev.Projection.Project
        (Svd, Policy_For
           (Svd, ", ""field_corrections"": {""UARTB.CR.READY"": {""add"":"
            & " true, ""bits"": ""[4:4]"", ""access"": ""read-only"","
            & " ""source"": ""the manual, p. 6""}}"),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault, US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/uartb/device.ldn"),
                         "    f_ready: u1 at 4..4" & LF)
         and then Contains (Output_Of (Made, "toy1/uartb/device.ldn"),
                            "public cr_named_mask: u32 = 0x00000017")
         and then not Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                                "f_ready"),
         "an added field is generated in its register alone");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/correspondence.json"),
                         """added"": true," & LF)
         and then Contains (Output_Of (Made, "toy1/correspondence.json"),
                            """source"": ""the manual, p. 6"""),
         "and recorded as added, with its source");
   end A_Correction_Is_Recorded;

   procedure A_Policy_Names_The_Core (Item : in out Landin.Testing.Context);

   --  D700, D701: a RISC-V device's core is its policy's, and on a core
   --  whose SVD interrupts are an interrupt matrix's sources they are a
   --  module of their own rather than slots.
   procedure A_Policy_Names_The_Core (Item : in out Landin.Testing.Context)
   is
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
      Riscv : constant String :=
        Replaced (Replaced (Svd, "<name>TOY1</name>", "<name>TOY-1</name>"),
                  "<name>CM7</name>", "<name>RV32IMC</name>");

      function Riscv_Policy (Rest : String) return String is
        (Replaced (Policy_For (Riscv, ", ""prefix"": ""toy1"","
                   & " ""description"": ""descriptions/toy1""" & Rest),
                   """device"": ""TOY1""", """device"": ""TOY-1"""));
   begin
      Dev.Projection.Project
        (Riscv, Riscv_Policy
           (", ""core"": ""esp-rv32imc"", ""interrupt_corrections"":"
            & " {""EXTRA_IRQ"": {""value"": 9, ""source"": ""the manual,"
            & " p. 3""}}"), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault, US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      Landin.Testing.Check_Equal
        (Item, Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
         "-- Interrupts of the TOY-1, from its SVD: vendor Example, version"
         & " 1.0." & LF
         & "-- SVD SHA-256 " & GNAT.SHA256.Digest (Riscv) & "." & LF
         & "-- Copyright the vendor." & LF
         & "-- SPDX-License-Identifier: Apache-2.0" & LF
         & "-- Generated from the SVD; memory.ldn beside it is written by"
         & " hand." & LF
         & "-- The policy adds EXTRA_IRQ at 9: the manual, p. 3." & LF
         & "-- Its interrupts are interrupt-matrix sources, not slots:"
         & " toy1/sources." & LF & LF
         & "compiler.device(""toy-1"")" & LF
         & "compiler.core(""esp-rv32imc"")" & LF
         & "compiler.vectors(32)" & LF,
         "a vectored core's description: its 32 slots and no interrupt");
      Landin.Testing.Check_Equal
        (Item, Output_Of (Made, "toy1/sources/device.ldn"),
         "-- Toy notice." & LF
         & "-- The TOY-1's interrupt-matrix sources: each is the number of"
         & " its map" & LF
         & "-- register, which routes it to a CPU interrupt line; none is a"
         & " vector slot." & LF
         & "-- The policy adds EXTRA_IRQ at 9: the manual, p. 3." & LF
         & "public uarta_irq: u32 = 2" & LF
         & "public uartb_irq: u32 = 3" & LF
         & "public extra_irq: u32 = 9" & LF,
         "the sources, each by its lowercased name, corrections included");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/outputs.json"),
                         """toy1/sources/device.ldn"": """
                         & GNAT.SHA256.Digest
                           (Output_Of (Made, "toy1/sources/device.ldn"))),
         "and the manifest owns the sources module");
      Dev.Projection.Project
        (Riscv, Riscv_Policy (", ""core"": ""esp-rv32imac-clic"""),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains
           (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
            "compiler.core(""esp-rv32imac-clic"")" & LF
            & "compiler.vectors(48)" & LF),
         "a CLIC core's 48 slots: " & US.To_String (Problem.Message));
      Dev.Projection.Project
        (Svd, Policy_For (Svd, ", ""core"": ""hazard3"", ""identity"":"
                          & " ""toy1-hazard3"""), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains
           (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
            LF & "compiler.device(""toy1-hazard3"")" & LF
            & "compiler.core(""hazard3"")" & LF
            & "compiler.vectors(20)" & LF
            & "compiler.interrupt(""UARTA_IRQ"", 2)" & LF)
         and then Output_Of (Made, "toy1/sources/device.ldn")
           = "absent: toy1/sources/device.ldn",
         "Hazard3 takes interrupt n at 16 + n, whatever the cpu says: "
         & US.To_String (Problem.Message));
      for Core in Landin.Targets.Firmware.Xtensa_Core loop
         declare
            package F renames Landin.Targets.Firmware;
            Name : constant String := F.Spelling (Core);
            Xtensa : constant String :=
              Replaced (Svd, "<name>CM7</name>",
                        "<name>" & F.Svd_Name (Core) & "</name>");
         begin
            for Explicit in Boolean loop
               Dev.Projection.Project
                 (Xtensa, Policy_For
                    (Xtensa, (if Explicit then
                       ", ""core"": """ & Name & """" else "")),
                  Made, Problem);
               Landin.Testing.Check
                 (Item, Problem.Kind = Dev.No_Fault
                  and then Contains
                    (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
                     "compiler.core(""" & Name & """)" & LF
                     & "compiler.vectors(32)" & LF)
                  and then not Contains
                    (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
                     "compiler.interrupt(")
                  and then Contains
                    (Output_Of (Made, "toy1/sources/device.ldn"),
                     "public uarta_irq: u32 = 2" & LF),
                  Name & " keeps matrix sources separate from CPU lines,"
                  & " with explicit or inferred core: "
                  & US.To_String (Problem.Message));
            end loop;
         end;
      end loop;
   end A_Policy_Names_The_Core;

   procedure Enumerations_Reuse_A_Named_Group
     (Item : in out Landin.Testing.Context);

   procedure Enumerations_Reuse_A_Named_Group
     (Item : in out Landin.Testing.Context)
   is
      Named : constant String :=
        Replaced
          (Replaced (Svd, "<enumeratedValues>",
                     "<enumeratedValues><name>Modes</name>"),
           "<bitRange>[0:0]</bitRange>", "<bitRange>[4:3]</bitRange>");
      Derived : constant String :=
        Replaced (Named,
                  "<modifiedWriteValues>oneToClear</modifiedWriteValues>",
                  "<modifiedWriteValues>oneToClear</modifiedWriteValues>"
                  & "<enumeratedValues derivedFrom=""Modes""/>");
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;

      function Policy (Text : String) return String is
        (Replaced (Policy_For (Text), "0x00000001", "0x00000018"));

      procedure Refuses (Text : String; Kind : Dev.Fault_Kind; Words : String);

      procedure Refuses (Text : String; Kind : Dev.Fault_Kind; Words : String)
      is
      begin
         Dev.Projection.Project (Text, Policy (Text), Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Kind
            and then Contains (US.To_String (Problem.Message), Words)
            and then Made.Outputs.Is_Empty,
            Words & ": " & US.To_String (Problem.Message));
      end Refuses;
   begin
      Dev.Projection.Project (Derived, Policy (Derived), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                            "cr_en_value: type = u2 (cr_en_off = 0 |"
                            & " cr_en_fast = 2)")
         and then Contains (Output_Of (Made, "toy1/correspondence.json"),
                            """encoding_derivation"": ""Modes"""),
         "same-register enum reuse retains values and provenance: "
         & US.To_String (Problem.Message));
      Refuses (Replaced (Derived, "derivedFrom=""Modes""",
                         "derivedFrom=""Missing"""),
               Dev.Inconsistent_Device, "absent enumeratedValues");
      Refuses (Replaced (Derived, "derivedFrom=""Modes""",
                         "derivedFrom=""UARTA.Modes"""),
               Dev.Unsupported_Form, "same register");
      Refuses (Replaced
                 (Derived, "<enumeratedValues derivedFrom=""Modes""/>",
                  "<enumeratedValues><name>Modes</name></enumeratedValues>"
                  & "<enumeratedValues derivedFrom=""Modes""/>"),
               Dev.Inconsistent_Device, "ambiguous enumeratedValues");
      Refuses (Replaced
                 (Derived, "<enumeratedValues derivedFrom=""Modes""/>",
                  "<enumeratedValues derivedFrom=""Modes"">"
                  & "<name>Local</name></enumeratedValues>"),
               Dev.Unsupported_Form, "children of its own");
      Refuses (Replaced (Derived, "<enumeratedValues><name>Modes</name>",
                         "<enumeratedValues derivedFrom=""Modes"">"
                         & "<name>Modes</name>"),
               Dev.Unsupported_Form, "chained or cyclic");
   end Enumerations_Reuse_A_Named_Group;

   procedure Interrupt_Corrections_Replace_Together
     (Item : in out Landin.Testing.Context);

   procedure Interrupt_Corrections_Replace_Together
     (Item : in out Landin.Testing.Context)
   is
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
      Corrections : constant String :=
        ", ""interrupt_corrections"": {"
        & """UARTA_IRQ"": {""value"": 3, ""source"": ""reviewed A""},"
        & """UARTB_IRQ"": {""value"": 2, ""source"": ""reviewed B""}}";
   begin
      Dev.Projection.Project
        (Svd, Policy_For (Svd, Corrections), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains
           (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
            "compiler.interrupt(""UARTB_IRQ"", 2)" & LF
            & "compiler.interrupt(""UARTA_IRQ"", 3)" & LF),
         "corrected sources may exchange numbers without a transient"
         & " collision: " & US.To_String (Problem.Message));
   end Interrupt_Corrections_Replace_Together;

   procedure An_Array_Element_Is_A_Register
     (Item : in out Landin.Testing.Context);

   --  D703: an element of a register array is selected by its name, and
   --  generated at its array's offset and increment.
   procedure An_Array_Element_Is_A_Register
     (Item : in out Landin.Testing.Context)
   is
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
      Arrayed : constant String :=
        Replaced (Svd, "      </registers>" & LF & "    </peripheral>" & LF
                  & "    <peripheral derivedFrom",
                  "        <register><name>PIN%s</name><dim>3</dim>"
                  & "<dimIncrement>0x4</dimIncrement><dimIndex>4-6"
                  & "</dimIndex><addressOffset>0x10</addressOffset>"
                  & "<fields><field><name>LVL</name><bitRange>[0:0]"
                  & "</bitRange><access>read-write</access></field></fields>"
                  & "</register>" & LF
                  & "      </registers>" & LF & "    </peripheral>" & LF
                  & "    <peripheral derivedFrom");

      function Selecting (Text, Name : String) return String is
        (Replaced
           (Replaced (Policy_For (Text), """UARTA"": [""CR"", ""CR_IN""]",
                      """UARTA"": [""CR"", ""CR_IN"", """ & Name & """]"),
            """UARTB.CR"":", """UARTA." & Name & """: {""read"":"
            & " ""normal"", ""write"": ""normal"", ""reserved"": ""zero""},"
            & " ""UARTB.CR"":"));
   begin
      Dev.Projection.Project (Arrayed, Selecting (Arrayed, "PIN5"),
                              Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault, US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                         "public pin5_offset: usize = 0x14" & LF
                         & "public pin5_address: usize = 0x40001014" & LF),
         "PIN5 is the second of 4-6, at 0x10 + 4");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/correspondence.json"),
                         """dim_element"": {" & LF
                         & "      ""array"": ""PIN%s""," & LF
                         & "      ""index"": ""5""" & LF & "    },"),
         "and its correspondence names the array and the index");
      Landin.Testing.Check
        (Item, not Contains (Output_Of (Made, "toy1/uartb/device.ldn"),
                             "pin"),
         "an element is generated only where it is selected");
      Dev.Projection.Project (Arrayed, Selecting (Arrayed, "PIN7"),
                              Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.Not_In_Svd
         and then Contains (US.To_String (Problem.Message),
                            "an index its dimIndex gives"),
         "an index the array lacks: " & US.To_String (Problem.Message));
      declare
         Short : constant String :=
           Replaced (Arrayed, "<dimIndex>4-6</dimIndex>",
                     "<dimIndex>4,5</dimIndex>");
      begin
         Dev.Projection.Project (Short, Selecting (Short, "PIN5"),
                                 Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.Inconsistent_Device
            and then Contains (US.To_String (Problem.Message),
                               "gives 2 indices for its dim 3"),
            "a dimIndex of another count: " & US.To_String (Problem.Message));
      end;
      declare
         Plain : constant String :=
           Replaced (Arrayed, "<dimIndex>4-6</dimIndex>", "");
      begin
         Dev.Projection.Project (Plain, Selecting (Plain, "PIN2"),
                                 Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.No_Fault
            and then Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                               "public pin2_offset: usize = 0x18" & LF),
            "without a dimIndex the indices are 0 to dim - 1: "
            & US.To_String (Problem.Message));
      end;
   end An_Array_Element_Is_A_Register;

   procedure A_Policy_Corrects_And_Adds_Registers
     (Item : in out Landin.Testing.Context);

   --  D704, D705: a reviewed offset in place of the SVD's, and a
   --  peripheral the SVD lacks, each with its source.
   procedure A_Policy_Corrects_And_Adds_Registers
     (Item : in out Landin.Testing.Context)
   is
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
      Addition : constant String :=
        ", ""peripheral_additions"": {""EXTRA"": {""base"": ""0x50000000"","
        & " ""source"": ""the manual, p. 7"", ""registers"": {""CTRL%s"":"
        & " {""offset"": ""0x100"", ""dim"": 4, ""increment"": ""0x8"","
        & " ""access"": ""read-write"", ""reset"": ""0x00000002"","
        & " ""fields"": {""GO"": {""bits"": ""[0:0]""}, ""BUSY"": {""bits"":"
        & " ""[1:1]"", ""access"": ""read-only""}}}}}}";

      function Adding (Rest : String) return String is
        (Replaced
           (Replaced (Policy_For (Svd, Rest), """UARTB"": [""CR""]",
                      """UARTB"": [""CR""], ""EXTRA"": [""CTRL2""]"),
            """UARTB.CR"":", """EXTRA.CTRL2"": {""read"": ""normal"","
            & " ""write"": ""normal"", ""reserved"": ""zero""},"
            & " ""UARTB.CR"":"));
   begin
      Dev.Projection.Project
        (Svd, Policy_For
           (Svd, ", ""register_corrections"": {""UARTB.CR"": {""offset"":"
            & " ""0x00000008"", ""source"": ""the manual, p. 2""}}"),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains (Output_Of (Made, "toy1/uartb/device.ldn"),
                            "public cr_offset: usize = 0x8" & LF
                            & "public cr_address: usize = 0x40002008" & LF)
         and then Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                            "public cr_offset: usize = 0x4" & LF)
         and then Contains (Output_Of (Made, "toy1/correspondence.json"),
                            """offset_correction"": {" & LF
                            & "      ""source"": ""the manual, p. 2""," & LF
                            & "      ""svd_offset"": 4" & LF & "    },"),
         "a corrected offset is generated and recorded beside the SVD's: "
         & US.To_String (Problem.Message));
      Dev.Projection.Project (Svd, Adding (Addition), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault, US.To_String (Problem.Message));
      if Problem.Kind /= Dev.No_Fault then
         return;
      end if;
      for Expected of Landin.Platform.Path_List'
        ["public base: usize = 0x50000000" & LF,
         "public ctrl2_offset: usize = 0x110" & LF
         & "public ctrl2_address: usize = 0x50000110" & LF
         & "public ctrl2_named_mask: u32 = 0x00000003" & LF
         & "public ctrl2_reset_mask: u32 = 0x00000003" & LF
         & "public ctrl2_reset_value: u32 = 0x00000002" & LF,
         "    f_go: u1 at 0..0" & LF & "    f_busy: u1 at 1..1" & LF]
      loop
         Landin.Testing.Check
           (Item, Contains (Output_Of (Made, "toy1/extra/device.ldn"),
                            Expected),
            "the added peripheral has: " & Expected);
      end loop;
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "toy1/correspondence.json"),
                         "  {" & LF & "    ""addition"": {" & LF
                         & "      ""source"": ""the manual, p. 7""" & LF
                         & "    }," & LF & "    ""address"": 1342177552,"),
         "and its register is recorded as added, with its source");
      Landin.Testing.Check
        (Item, Contains (Output_Of (Made, "descriptions/toy1/"
                                    & "interrupts.ldn"),
                         "compiler.vectors(20)"),
         "an addition has no interrupts of its own");
      declare
         Overlapping : constant String :=
           Replaced (Addition, """[1:1]""", """[1:0]""");
      begin
         Dev.Projection.Project (Svd, Adding (Overlapping), Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.Inconsistent_Device
            and then Problem.Within = Dev.Policy_Input
            and then not Problem.Has_Offset
            and then Contains (US.To_String (Problem.Message),
                               "in the policy's peripheral_additions,"
                               & " EXTRA.CTRL2.BUSY overlaps"),
            "a fault in what the policy adds is the policy's: "
            & US.To_String (Problem.Message));
      end;
   end A_Policy_Corrects_And_Adds_Registers;

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

         procedure Linked_Ancestor
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
         procedure Linked_Ancestor
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_Link ("out/toy1");
         end Linked_Ancestor;

         procedure Linked_Leftover
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
         procedure Linked_Leftover
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_Link ("out/toy1/outputs.json.refine-old");
         end Linked_Leftover;

         procedure Input_Alias
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
         procedure Input_Alias
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/toy1/correspondence.json", Svd);
            Host.Add_Alias ("out/toy1/correspondence.json", "toy.svd");
         end Input_Alias;

         procedure Protected_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
         procedure Protected_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/toy1/outputs.json",
                           "{""old.svd"": ""0""}");
            Host.Add_File ("out/old.svd", Svd);
            Host.Add_Alias ("out/old.svd", "toy.svd");
         end Protected_Stale;

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

         --  D1064: the old manifest names a file this run does not make,
         --  a developer's, a module edited since it was written, or one
         --  whose entry records no hash; none is the bytes its entry
         --  records, and none is removed.
         procedure Foreign_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Foreign_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/descriptions/toy1/memory.ldn", "mine");
            Host.Add_File
              ("out/toy1/outputs.json",
               "{""descriptions/toy1/memory.ldn"": """
               & [1 .. 64 => '0'] & """}");
         end Foreign_Stale;

         procedure Edited_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Edited_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/toy1/old/device.ldn", "edited" & LF);
            Host.Add_File
              ("out/toy1/outputs.json",
               "{""toy1/old/device.ldn"": """
               & GNAT.SHA256.Digest ("generated" & LF) & """}");
         end Edited_Stale;

         procedure Unhashed_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure Unhashed_Stale
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_File ("out/toy1/old/device.ldn", "generated" & LF);
            Host.Add_File
              ("out/toy1/outputs.json", "{""toy1/old/device.ldn"": 1}");
         end Unhashed_Stale;

         procedure No_Svd
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

         procedure No_Svd
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
         begin
            Host.Add_Unreadable ("toy.svd");
         end No_Svd;
      begin
         Refused (Leftover'Access, "L0531", "interrupted run");
         Refused (Linked_Leftover'Access, "L0531", "interrupted run");
         Refused (Linked_Ancestor'Access, "L0531", "symbolic link");
         Refused (Input_Alias'Access, "L0531", "overlaps an input");
         Refused (Protected_Stale'Access, "L0531", "overlaps an input");
         Refused (Directory_In_The_Way'Access, "L0531", "is a directory");
         Refused (No_Output_Directory'Access, "L0531", "not a directory");
         Refused (Unwritable'Access, "L0531", "unwritable");
         Refused (Foreign_Manifest'Access, "L0531", "not a path below it");
         Refused (No_Svd'Access, "L0003", "cannot read the SVD");
         Refused (Foreign_Stale'Access, "L0531",
                  "names out/descriptions/toy1/memory.ldn, which this run"
                  & " no longer makes and would remove, but it is not the"
                  & " file the manifest says refine svd wrote");
         Refused (Edited_Stale'Access, "L0531",
                  "names out/toy1/old/device.ldn, which this run no longer"
                  & " makes");
         Refused (Unhashed_Stale'Access, "L0531",
                  "names out/toy1/old/device.ldn, which this run no longer"
                  & " makes");
      end;
      --  What a refusal for a stale file leaves is the file.
      declare
         Host : Landin.Testing.Fakes.Fake_Filesystem;
      begin
         Prepare (Host);
         Host.Add_File ("out/descriptions/toy1/memory.ldn", "mine");
         Host.Add_File ("out/toy1/old/device.ldn", "generated" & LF);
         Host.Add_File
           ("out/toy1/outputs.json",
            "{""descriptions/toy1/memory.ldn"": """
            & [1 .. 64 => '0'] & """, ""toy1/old/device.ldn"": """
            & GNAT.SHA256.Digest ("generated" & LF) & """}");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (Arguments, Host, Tools, Meter);
         begin
            Landin.Testing.Check
              (Item, Result.Status = Landin.Driver.Status_Reported
               and then Content_Of (Host, "out/descriptions/toy1/memory.ldn")
                 = "mine"
               and then Host.Exists ("out/toy1/old/device.ldn")
               and then not Host.Exists ("out/toy1/uarta/device.ldn"),
               "a developer's file the manifest names is kept, and nothing"
               & " is replaced: " & Code_Of (Result));
         end;
         --  With only the file it wrote named, that file goes.
         Host.Add_File
           ("out/toy1/outputs.json",
            "{""toy1/old/device.ldn"": """
            & GNAT.SHA256.Digest ("generated" & LF) & """}");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (Arguments, Host, Tools, Meter);
         begin
            Landin.Testing.Check
              (Item, Result.Status = 0
               and then Contains (US.To_String (Result.Output),
                                  "1 no longer made removed")
               and then not Host.Exists ("out/toy1/old/device.ldn")
               and then Content_Of (Host, "out/descriptions/toy1/memory.ldn")
                 = "mine",
               "a stale file that is still what was written is removed: "
               & Code_Of (Result));
         end;
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

   --  One refusal of the projection: its kind, words of its message, and
   --  the line of the SVD it points at when one is given.
   procedure Expect_Refusal
     (Item : in out Landin.Testing.Context;
      Text : String; Kind : Dev.Fault_Kind; Words : String;
      Line : Natural := 0; Policy : String := "");

   procedure Expect_Refusal
     (Item : in out Landin.Testing.Context;
      Text : String; Kind : Dev.Fault_Kind; Words : String;
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
         Landin.Testing.Check
           (Item, Problem.Has_Offset and then Problem.Within = Dev.Svd_Input,
            "placed in the SVD: " & Words);
         Landin.Testing.Check_Equal
           (Item, Landin.Xml.Line_Of (Document, Problem.Offset), Line,
            "where: " & Words);
      end if;
   end Expect_Refusal;

   --  The toy with a register array PIN%s of three, indexed 4 to 6, and a
   --  policy for it that selects one more register of UARTA.
   Arrayed_Svd : constant String :=
     Replaced (Svd, "      </registers>" & LF & "    </peripheral>" & LF
               & "    <peripheral derivedFrom",
               "        <register><name>PIN%s</name><dim>3</dim>"
               & "<dimIncrement>0x4</dimIncrement><dimIndex>4-6"
               & "</dimIndex><addressOffset>0x10</addressOffset>"
               & "<fields><field><name>LVL</name><bitRange>[0:0]"
               & "</bitRange><access>read-write</access></field></fields>"
               & "</register>" & LF
               & "      </registers>" & LF & "    </peripheral>" & LF
               & "    <peripheral derivedFrom");

   function Selecting (Text, Name : String) return String is
     (Replaced
        (Replaced (Policy_For (Text), """UARTA"": [""CR"", ""CR_IN""]",
                   """UARTA"": [""CR"", ""CR_IN"", """ & Name & """]"),
         """UARTB.CR"":", """UARTA." & Name & """: {""read"":"
         & " ""normal"", ""write"": ""normal"", ""reserved"": ""zero""},"
         & " ""UARTB.CR"":"));

   procedure What_An_Svd_Omits_Or_Overstates_Is_Refused
     (Item : in out Landin.Testing.Context);

   --  D1062: a child the projection reads and the SVD omits is refused at
   --  its element, and each of an SVD's 64-bit numbers is bounded before
   --  it is added to another, so neither ends in an exception or passes a
   --  wrapped sum as a bit position, an address or a vector count.
   procedure What_An_Svd_Omits_Or_Overstates_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      procedure Expect
        (Text : String; Kind : Dev.Fault_Kind; Words : String;
         Line : Natural := 0; Policy : String := "");

      procedure Expect
        (Text : String; Kind : Dev.Fault_Kind; Words : String;
         Line : Natural := 0; Policy : String := "") is
      begin
         Expect_Refusal (Item, Text, Kind, Words, Line, Policy);
      end Expect;

      No_Increment : constant String :=
        Replaced (Arrayed_Svd, "<dimIncrement>0x4</dimIncrement>", "");
      Far_Increment : constant String :=
        Replaced (Arrayed_Svd, "<dimIncrement>0x4</dimIncrement>",
                  "<dimIncrement>0xFFFFFFFFFFFFFFFC</dimIncrement>");
      Far_Array : constant String :=
        Replaced (Arrayed_Svd, "<addressOffset>0x10</addressOffset>",
                  "<addressOffset>0xFFFFFFFF00000010</addressOffset>");
   begin
      --  An interrupt of a peripheral nothing selects is read too.
      Expect (Replaced (Svd, "<name>UARTB_IRQ</name><value>3</value>",
                        "<name>UARTB_IRQ</name>"),
              Dev.Inconsistent_Device,
              "an interrupt's value is missing: this <interrupt> has no"
              & " <value>", 43);
      Expect (No_Increment, Dev.Inconsistent_Device,
              "PIN%s's dimIncrement is missing: this <register> has no"
              & " <dimIncrement>", 38,
              Policy => Selecting (No_Increment, "PIN5"));
      --  bitOffset + bitWidth wraps to 0 and to 16.
      Expect (Replaced (Svd, "<bitOffset>1</bitOffset><bitWidth>2</bitWidth>",
                        "<bitOffset>0xFFFFFFFFFFFFFFFF</bitOffset>"
                        & "<bitWidth>1</bitWidth>"),
              Dev.Inconsistent_Device, "lies outside its 32-bit register",
              24);
      Expect (Replaced (Svd, "<bitOffset>1</bitOffset><bitWidth>2</bitWidth>",
                        "<bitOffset>0xFFFFFFFFFFFFFFF0</bitOffset>"
                        & "<bitWidth>0x20</bitWidth>"),
              Dev.Inconsistent_Device, "lies outside its 32-bit register",
              24);
      Expect (Replaced (Svd, "<bitOffset>1</bitOffset><bitWidth>2</bitWidth>",
                        "<bitOffset>31</bitOffset><bitWidth>2</bitWidth>"),
              Dev.Inconsistent_Device, "lies outside its 32-bit register",
              24);
      --  0x40001000 + 0xFFFFFFFFC0000004 wraps to 0x00001004.
      Expect (Replaced (Svd, "<name>CR</name>" & LF
                        & "          <addressOffset>0x4</addressOffset>",
                        "<name>CR</name>" & LF & "          <addressOffset>"
                        & "0xFFFFFFFFC0000004</addressOffset>"),
              Dev.Inconsistent_Device, "not a word-aligned 32-bit address",
              20);
      Expect (Far_Increment, Dev.Inconsistent_Device,
              "PIN%s's dimIncrement is beyond 32 bits", 38,
              Policy => Selecting (Far_Increment, "PIN5"));
      Expect (Far_Array, Dev.Inconsistent_Device,
              "not a word-aligned 32-bit address", 38,
              Policy => Selecting (Far_Array, "PIN5"));
      --  16 + deviceNumInterrupts wraps to 15.
      Expect (Replaced (Svd, "<deviceNumInterrupts>4<",
                        "<deviceNumInterrupts>0xFFFFFFFFFFFFFFFF<"),
              Dev.Inconsistent_Device, "beyond any vector table", 8);
      declare
         Made : Dev.Projection.Result;
         Problem : Dev.Fault;
         Most : constant String :=
           Replaced (Svd, "<deviceNumInterrupts>4<",
                     "<deviceNumInterrupts>65536<");
      begin
         Dev.Projection.Project (Most, Policy_For (Most), Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.No_Fault
            and then Contains
              (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
               "compiler.vectors(65552)" & LF),
            "the largest table is read: " & US.To_String (Problem.Message));
      end;
   end What_An_Svd_Omits_Or_Overstates_Is_Refused;

   procedure An_Ambiguous_Svd_Is_Refused
     (Item : in out Landin.Testing.Context);

   --  D1062: where a selected name has two readings in the SVD, the second
   --  is refused rather than the first taken.
   procedure An_Ambiguous_Svd_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      Second_Register : constant String :=
        Replaced (Svd, "        <register>" & LF
                  & "          <name>CR_IN</name>",
                  "        <register><name>CR</name><addressOffset>0x40"
                  & "</addressOffset><fields><field><name>X</name>"
                  & "<bitRange>[31:28]</bitRange></field></fields>"
                  & "</register>" & LF
                  & "        <register>" & LF
                  & "          <name>CR_IN</name>");
      Second_Peripheral : constant String :=
        Replaced (Svd, "  </peripherals>",
                  "    <peripheral><name>UARTA</name><baseAddress>0x50000000"
                  & "</baseAddress></peripheral>" & LF & "  </peripherals>");
      --  PIN5 is the second element of PIN%s, and now a register too.
      Named_And_Element : constant String :=
        Replaced (Arrayed_Svd, "        <register><name>PIN%s</name>",
                  "        <register><name>PIN5</name><addressOffset>0x80"
                  & "</addressOffset><fields><field><name>X</name>"
                  & "<bitRange>[0:0]</bitRange></field></fields>"
                  & "</register>" & LF
                  & "        <register><name>PIN%s</name>");
      Two_Arrays : constant String :=
        Replaced (Arrayed_Svd, "        <register><name>PIN%s</name>",
                  "        <register><name>P%s5</name><dim>2</dim>"
                  & "<dimIncrement>4</dimIncrement><dimIndex>IN,OUT"
                  & "</dimIndex><addressOffset>0x80</addressOffset>"
                  & "<fields><field><name>X</name><bitRange>[0:0]"
                  & "</bitRange></field></fields></register>" & LF
                  & "        <register><name>PIN%s</name>");
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
   begin
      Expect_Refusal
        (Item, Second_Register, Dev.Inconsistent_Device,
         "the SVD gives UARTA.CR twice, and does not say which is meant",
         32);
      Expect_Refusal
        (Item, Second_Peripheral, Dev.Inconsistent_Device,
         "the SVD has two peripherals named UARTA", 46);
      --  The peripheral a selected one is derived from is one too.
      Expect_Refusal
        (Item, Second_Peripheral, Dev.Inconsistent_Device,
         "the SVD has two peripherals named UARTA", 46,
         Policy => Replaced
           (Replaced (Policy_For (Second_Peripheral),
                      """UARTA"": [""CR"", ""CR_IN""], ", ""),
            """UARTA.CR"": {""read"": ""normal"", ""write"": ""one_clears"","
            & " ""reserved"": ""zero"", ""write_mask"": ""0x00000001""},"
            & """UARTA.CR_IN"": {""read"": ""normal"", ""write"":"
            & " ""refused"", ""reserved"": ""zero""},", ""));
      Expect_Refusal
        (Item, Named_And_Element, Dev.Inconsistent_Device,
         "the SVD gives UARTA.PIN5 twice, as a register of that name or as"
         & " an element of an array (dim)", 39,
         Policy => Selecting (Named_And_Element, "PIN5"));
      Expect_Refusal
        (Item, Two_Arrays, Dev.Inconsistent_Device,
         "the SVD gives UARTA.PIN5 twice, as a register of that name or as"
         & " an element of an array (dim)", 39,
         Policy => Selecting (Two_Arrays, "PIN5"));
      --  Another element of the same array is not ambiguous.
      Dev.Projection.Project
        (Named_And_Element, Selecting (Named_And_Element, "PIN6"),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                            "public pin6_offset: usize = 0x18" & LF),
         "PIN6 has one reading: " & US.To_String (Problem.Message));
      --  A field's position given in two forms.
      Expect_Refusal
        (Item, Replaced (Svd, "<bitRange>[0:0]</bitRange>",
                         "<bitRange>[0:0]</bitRange><lsb>3</lsb>"
                         & "<msb>3</msb>"),
         Dev.Inconsistent_Device,
         "UARTA.CR.EN gives its position in two forms that disagree: bits"
         & " 0 to 0, and bits 3 to 3", 29);
      Expect_Refusal
        (Item, Replaced (Svd, "<lsb>8</lsb><msb>15</msb>",
                         "<lsb>8</lsb><msb>15</msb><bitOffset>8</bitOffset>"
                         & "<bitWidth>4</bitWidth>"),
         Dev.Inconsistent_Device, "two forms that disagree: bits 8 to 11,"
         & " and bits 8 to 15", 36);
      declare
         Agreeing : constant String :=
           Replaced (Svd, "<bitRange>[0:0]</bitRange>",
                     "<bitRange>[0:0]</bitRange><lsb>0</lsb><msb>0</msb>"
                     & "<bitOffset>0</bitOffset><bitWidth>1</bitWidth>");
      begin
         Dev.Projection.Project
           (Agreeing, Policy_For (Agreeing), Made, Problem);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.No_Fault
            and then Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                               "    f_en: u1 at 0..0" & LF),
            "three forms that agree are one position: "
            & US.To_String (Problem.Message));
      end;
   end An_Ambiguous_Svd_Is_Refused;

   procedure A_Reserved_Name_Is_Refused
     (Item : in out Landin.Testing.Context);

   --  D1063: a name the importer writes with nothing added is refused
   --  when Landin reserves it, rather than written into a module that no
   --  program can compile or import.
   procedure A_Reserved_Name_Is_Refused
     (Item : in out Landin.Testing.Context)
   is
      function Esp (Text : String; Rest : String := "") return String is
        (Policy_For (Text, ", ""core"": ""esp-rv32imc""" & Rest));

      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
   begin
      for Name of Landin.Platform.Path_List'
        ["END", "Type", "match", "COMPILER", "linker"]
      loop
         declare
            Keyword : constant String :=
              Replaced (Svd, "<name>UARTB_IRQ</name>",
                        "<name>" & Name & "</name>");
         begin
            Expect_Refusal
              (Item, Keyword, Dev.Unsupported_Form,
               "the interrupt " & Name & " would be the source "
               & Dev.Lowered (Name) & ", a name Landin reserves",
               Policy => Esp (Keyword));
            --  As a slot its name is a string, and no declaration.
            Dev.Projection.Project
              (Keyword, Policy_For (Keyword), Made, Problem);
            Landin.Testing.Check
              (Item, Problem.Kind = Dev.No_Fault
               and then Contains
                 (Output_Of (Made, "descriptions/toy1/interrupts.ldn"),
                  "compiler.interrupt(""" & Name & """, 3)" & LF),
               Name & " is a slot's name: "
               & US.To_String (Problem.Message));
            --  And the policy can leave the source out.
            Dev.Projection.Project
              (Keyword,
               Esp (Keyword, ", ""interrupt_corrections"": {""" & Name
                    & """: {""omit"": true, ""source"": ""reserved""}}"),
               Made, Problem);
            Landin.Testing.Check
              (Item, Problem.Kind = Dev.No_Fault
               and then Contains
                 (Output_Of (Made, "toy1/sources/device.ldn"),
                  "public uarta_irq: u32 = 2" & LF),
               Name & " omitted: " & US.To_String (Problem.Message));
         end;
      end loop;
      declare
         Module : constant String :=
           Replaced (Svd, "<name>UARTB</name>", "<name>End</name>");
      begin
         Expect_Refusal
           (Item, Module, Dev.Unsupported_Form,
            "the peripheral End would be the module end, a name Landin"
            & " reserves", 40,
            Policy => Replaced
              (Replaced (Policy_For (Module), """UARTB"": [""CR""]",
                         """End"": [""CR""]"),
               """UARTB.CR""", """End.CR"""));
      end;
      Expect_Refusal
        (Item, Svd, Dev.Invalid_Policy,
         "the policy's prefix has the part type, a name Landin reserves",
         Policy => Policy_For (Svd, ", ""prefix"": ""chips/type"""));
   end A_Reserved_Name_Is_Refused;

   procedure Outputs_Do_Not_Overlap (Item : in out Landin.Testing.Context);

   --  D1064: the policy's paths are compared as they are written, the
   --  modules' root included, and none may be another or lie below it.
   procedure Outputs_Do_Not_Overlap (Item : in out Landin.Testing.Context)
   is
      procedure Expect (Rest, Words : String);

      procedure Expect (Rest, Words : String) is
      begin
         Expect_Refusal (Item, Svd, Dev.Invalid_Policy, Words,
                         Policy => Policy_For (Svd, Rest));
      end Expect;

      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
   begin
      Expect (", ""modules"": ""gen"", ""manifest"":"
              & " ""toy1/uarta/device.ldn""",
              "write two outputs to gen/toy1/uarta/device.ldn");
      Expect (", ""manifest"": ""toy1/uarta/device.ldn""",
              "write two outputs to toy1/uarta/device.ldn");
      Expect (", ""modules"": ""gen"", ""correspondence"":"
              & " ""toy1/uartb/device.ldn""",
              "write two outputs to gen/toy1/uartb/device.ldn");
      Expect (", ""modules"": ""gen"", ""description"": ""gen/toy1"","
              & " ""manifest"": ""toy1/interrupts.ldn""",
              "write two outputs to gen/toy1/interrupts.ldn");
      Expect (", ""modules"": ""gen"", ""manifest"":"
              & " ""toy1/uarta/device.ldn/x.json""",
              "write gen/toy1/uarta/device.ldn as a file and"
              & " gen/toy1/uarta/device.ldn/x.json below it");
      Expect (", ""correspondence"": ""toy1/uarta""",
              "write toy1/uarta as a file and toy1/uarta/device.ldn below"
              & " it");
      Expect (", ""description"": ""toy1/outputs.json""",
              "write toy1/outputs.json as a file and"
              & " toy1/outputs.json/interrupts.ldn below it");
      --  A name that only begins as another does is no directory above it.
      Dev.Projection.Project
        (Svd, Policy_For (Svd, ", ""modules"": ""gen"", ""manifest"":"
                          & " ""toy1/uarta/device.ldn.json"","
                          & " ""correspondence"": ""toy1/uarta-map"""),
         Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then US.To_String (Made.Manifest)
           = "gen/toy1/uarta/device.ldn.json"
         and then Contains
           (Output_Of (Made, "gen/toy1/uarta/device.ldn.json"),
            """toy1/uarta-map"": """)
         and then not Contains
           (Output_Of (Made, "gen/toy1/uarta/device.ldn.json"),
            "device.ldn.json"),
         "distinct paths are written, the manifest under the root and not"
         & " listing itself: " & US.To_String (Problem.Message));
   end Outputs_Do_Not_Overlap;

   procedure A_Large_Svd_Costs_In_Proportion
     (Item : in out Landin.Testing.Context);

   --  D1062: an element's attributes, a field's enumerated values and a
   --  device's interrupts are each read in time that grows with their
   --  number, not with its square.  Four times as many may take four times
   --  as long and a logarithm more; the comparisons each of the three once
   --  made of every item with every other took sixteen.  Processor time is
   --  measured, which other work on the host does not lengthen.
   procedure A_Large_Svd_Costs_In_Proportion
     (Item : in out Landin.Testing.Context)
   is
      use type Ada.Execution_Time.CPU_Time;

      Small : constant := 8_000;
      Large : constant := 4 * Small;

      function Image (Value : Natural) return String is
        (Dev.Decimal (Dev.Word (Value)));

      function Attributes (Count : Positive) return String;

      function Attributes (Count : Positive) return String is
         Text : US.Unbounded_String;
      begin
         for Index in 1 .. Count loop
            US.Append (Text, " a" & Image (Index) & "=""x""");
         end loop;
         return Replaced (Svd, "<cpu>", "<cpu" & US.To_String (Text) & ">");
      end Attributes;

      function Values (Count : Positive) return String;

      function Values (Count : Positive) return String is
         Text : US.Unbounded_String;
      begin
         for Index in 1 .. Count loop
            US.Append (Text, "<enumeratedValue><name>V" & Image (Index)
                       & "</name><value>" & Image (Index)
                       & "</value></enumeratedValue>");
         end loop;
         return Replaced
           (Svd, "<field><name>LEVEL</name><lsb>8</lsb><msb>15</msb>",
            "<field><name>LEVEL</name><lsb>0</lsb><msb>31</msb>"
            & "<enumeratedValues>" & US.To_String (Text)
            & "</enumeratedValues>");
      end Values;

      --  Descending, the order a search from the front is slowest in.
      function Interrupts (Count : Positive) return String;

      function Interrupts (Count : Positive) return String is
         Text : US.Unbounded_String;
      begin
         for Index in 1 .. Count loop
            US.Append (Text, "<interrupt><name>I" & Image (Index)
                       & "</name><value>" & Image (Count - Index + 4)
                       & "</value></interrupt>");
         end loop;
         return Replaced (Svd, "<name>UARTB</name>",
                          "<name>UARTB</name>" & US.To_String (Text));
      end Interrupts;

      function Seconds (Text, Expected : String) return Duration;

      function Seconds (Text, Expected : String) return Duration is
         Policy : constant String := Policy_For (Text);
         Made : Dev.Projection.Result;
         Problem : Dev.Fault;
         Began : constant Ada.Execution_Time.CPU_Time :=
           Ada.Execution_Time.Clock;
         Took : Duration;
      begin
         Dev.Projection.Project (Text, Policy, Made, Problem);
         Took := Ada.Real_Time.To_Duration (Ada.Execution_Time.Clock - Began);
         Landin.Testing.Check
           (Item, Problem.Kind = Dev.No_Fault
            and then (for some Output of Made.Outputs =>
                        Contains (US.To_String (Output.Content), Expected)),
            "the large SVD is read: " & Expected & " "
            & US.To_String (Problem.Message));
         return Took;
      end Seconds;

      procedure Compare (What : String; Lesser, Greater : Duration);

      procedure Compare (What : String; Lesser, Greater : Duration) is
      begin
         --  A floor under the lesser keeps a clock's grain from deciding.
         Landin.Testing.Check
           (Item, Greater <= 10 * Duration'Max (Lesser, 0.02),
            What & ": " & Image (Small) & " took"
            & Duration'Image (Lesser) & " s and " & Image (Large) & " took"
            & Duration'Image (Greater) & " s, more than ten times as long");
      end Compare;
   begin
      Compare ("attributes of one element",
               Seconds (Attributes (Small), "public cr_offset"),
               Seconds (Attributes (Large), "public cr_offset"));
      Compare ("enumerated values of one field",
               Seconds (Values (Small),
                        "public cr_in_level_v" & Image (Small) & ": atom"),
               Seconds (Values (Large),
                        "public cr_in_level_v" & Image (Large) & ": atom"));
      Compare ("interrupts of one device",
               Seconds (Interrupts (Small),
                        "compiler.interrupt(""I1"", " & Image (Small + 3)
                        & ")"),
               Seconds (Interrupts (Large),
                        "compiler.interrupt(""I1"", " & Image (Large + 3)
                        & ")"));
   end A_Large_Svd_Costs_In_Proportion;

   procedure An_Alternate_Of_An_Element_Is_At_Its_Address
     (Item : in out Landin.Testing.Context);

   --  An alternate that names an element of a register array is held to
   --  that element's address, the array's first and its position's
   --  dimIncrements, not to the array's first: PIN5 is the second of
   --  PIN%s, at 0x14.
   procedure An_Alternate_Of_An_Element_Is_At_Its_Address
     (Item : in out Landin.Testing.Context)
   is
      function Alternate_At (Offset : String; Text : String := Arrayed_Svd)
        return String
      is (Replaced
            (Text, "        <register><name>PIN%s</name>",
             "        <register><name>PALT</name><alternateRegister>PIN5"
             & "</alternateRegister><addressOffset>" & Offset
             & "</addressOffset><fields><field><name>X</name><bitRange>"
             & "[0:0]</bitRange><access>read-only</access></field></fields>"
             & "</register>" & LF
             & "        <register><name>PIN%s</name>"));

      At_Element : constant String := Alternate_At ("0x14");
      At_First : constant String := Alternate_At ("0x10");
      At_Last : constant String := Alternate_At ("0x18");
      No_Increment : constant String :=
        Alternate_At
          ("0x10",
           Replaced (Arrayed_Svd, "<dimIncrement>0x4</dimIncrement>", ""));
      Far_Increment : constant String :=
        Alternate_At
          ("0x14",
           Replaced (Arrayed_Svd, "<dimIncrement>0x4</dimIncrement>",
                     "<dimIncrement>0x100000004</dimIncrement>"));
      Made : Dev.Projection.Result;
      Problem : Dev.Fault;
   begin
      Dev.Projection.Project
        (At_Element, Selecting (At_Element, "PALT"), Made, Problem);
      Landin.Testing.Check
        (Item, Problem.Kind = Dev.No_Fault
         and then Contains (Output_Of (Made, "toy1/uarta/device.ldn"),
                            "public palt_offset: usize = 0x14" & LF),
         "an alternate at its element's address is generated: "
         & US.To_String (Problem.Message));
      Expect_Refusal
        (Item, At_First, Dev.Inconsistent_Device,
         "UARTA.PALT is an alternate of PIN5, which is at another address",
         38, Policy => Selecting (At_First, "PALT"));
      Expect_Refusal
        (Item, At_Last, Dev.Inconsistent_Device,
         "UARTA.PALT is an alternate of PIN5, which is at another address",
         38, Policy => Selecting (At_Last, "PALT"));
      --  The array's increment is read, so one it lacks is refused, and
      --  one beyond 32 bits is no address to be at.
      Expect_Refusal
        (Item, No_Increment, Dev.Inconsistent_Device,
         "PIN%s's dimIncrement is missing", 39,
         Policy => Selecting (No_Increment, "PALT"));
      Expect_Refusal
        (Item, Far_Increment, Dev.Inconsistent_Device,
         "UARTA.PALT is an alternate of PIN5, which is at another address",
         38, Policy => Selecting (Far_Increment, "PALT"));
   end An_Alternate_Of_An_Element_Is_At_Its_Address;

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
        (Into, "devices", "a policy names the core",
         A_Policy_Names_The_Core'Access);
      Landin.Testing.Register
        (Into, "devices", "enumerations reuse a named group",
         Enumerations_Reuse_A_Named_Group'Access);
      Landin.Testing.Register
        (Into, "devices", "interrupt corrections replace together",
         Interrupt_Corrections_Replace_Together'Access);
      Landin.Testing.Register
        (Into, "devices", "an array element is a register",
         An_Array_Element_Is_A_Register'Access);
      Landin.Testing.Register
        (Into, "devices", "a policy corrects and adds registers",
         A_Policy_Corrects_And_Adds_Registers'Access);
      Landin.Testing.Register
        (Into, "devices", "outputs are replaced whole",
         Outputs_Are_Replaced_Whole'Access);
      Landin.Testing.Register
        (Into, "devices", "each fault has its code",
         Each_Fault_Has_Its_Code'Access);
      Landin.Testing.Register
        (Into, "devices", "what an SVD omits or overstates is refused",
         What_An_Svd_Omits_Or_Overstates_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "devices", "an ambiguous SVD is refused",
         An_Ambiguous_Svd_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "devices", "an alternate of an element is at its address",
         An_Alternate_Of_An_Element_Is_At_Its_Address'Access);
      Landin.Testing.Register
        (Into, "devices", "a reserved name is refused",
         A_Reserved_Name_Is_Refused'Access);
      Landin.Testing.Register
        (Into, "devices", "outputs do not overlap",
         Outputs_Do_Not_Overlap'Access);
      Landin.Testing.Register
        (Into, "devices", "a large SVD costs in proportion",
         A_Large_Svd_Costs_In_Proportion'Access);
   end Register;

end Landin.Tests.Devices_Suite;
