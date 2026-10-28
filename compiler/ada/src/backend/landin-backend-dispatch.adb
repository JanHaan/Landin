with Landin.Backend.X86_64;
with Landin.Backend.Arm64;
with Landin.Backend.RiscV;
with Landin.Backend.Cortex_M;
with Landin.Targets.Capabilities;

package body Landin.Backend.Dispatch is

   function Frame_Limit (Facts : Landin.Targets.Target_Facts) return String is
     (case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.X86_64_ELF =>
            "signed 32-bit offsets this backend addresses",
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
           | Landin.Targets.Capabilities.Arm64_ELF =>
            "signed 32-bit frame budget of the arm64 backend",
         when Landin.Targets.Capabilities.RV64_ELF =>
            "signed 32-bit frame budget of the RV64 backend",
         when Landin.Targets.Capabilities.Cortex_M0_ELF =>
            "32-bit address budget of the Cortex-M backend",
         when Landin.Targets.Capabilities.No_Backend =>
            "frame encoding of an unavailable backend");

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean is
   begin
      case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.X86_64_ELF =>
            return Landin.Backend.X86_64.Frame_Is_Addressable
              (Of_Unit, Item, Facts, Options);
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
           | Landin.Targets.Capabilities.Arm64_ELF =>
            return Landin.Backend.Arm64.Frame_Is_Addressable
              (Of_Unit, Item, Facts, Options);
         when Landin.Targets.Capabilities.RV64_ELF =>
            return Landin.Backend.RiscV.Frame_Is_Addressable
              (Of_Unit, Item, Facts, Options);
         when Landin.Targets.Capabilities.Cortex_M0_ELF =>
            return Landin.Backend.Cortex_M.Frame_Is_Addressable
              (Of_Unit, Item, Facts, Options);
         when Landin.Targets.Capabilities.No_Backend => return False;
      end case;
   end Frame_Is_Addressable;

   function Frame_Fits_Firmware_Stack
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts) return Boolean is
   begin
      return Landin.Backend.Cortex_M.Frame_Fits_Firmware_Stack
        (Of_Unit, Item, Facts);
   end Frame_Fits_Firmware_Stack;

   --  Each figure is the emitted code's own, read from its backend:
   --  x86-64's switch is CALL's return address and six pushes, its
   --  prepared frame six registers, the start routine's address and
   --  sixteen bytes of padding, and its start routine calls the entry
   --  sixteen bytes below the top; arm64 and RV64 save their callee-saved
   --  sets in one frame of 160 and 208 bytes that their start routines
   --  pop entirely before a call that pushes nothing; Cortex-M0 pushes
   --  forty bytes, D460's frame.  Linux x86-64's report is a system call
   --  behind CALL's return address, FreeBSD's keeps a frame and calls
   --  `write`; arm64's keeps a frame record and calls `write` off Linux;
   --  RV64's keeps a frame record.
   function Stack_Facts_Of
     (Facts : Landin.Targets.Target_Facts) return Stack_Facts
   is
      use type Landin.Targets.Capabilities.Hosted_System;
      Linux : constant Boolean :=
        Landin.Targets.Capabilities.Hosted_System_Of (Facts)
          = Landin.Targets.Capabilities.Linux;
   begin
      case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.X86_64_ELF =>
            return (Switch_Bytes => 56, Prepared_Bytes => 72,
                    Entry_Bytes => 16,
                    Report_Bytes => (if Linux then 8 else 24),
                    Report_Foreign => not Linux);
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
           | Landin.Targets.Capabilities.Arm64_ELF =>
            return (Switch_Bytes => 160, Prepared_Bytes => 160,
                    Entry_Bytes => 0, Report_Bytes => 16,
                    Report_Foreign => not Linux);
         when Landin.Targets.Capabilities.RV64_ELF =>
            return (Switch_Bytes => 208, Prepared_Bytes => 208,
                    Entry_Bytes => 0, Report_Bytes => 16,
                    Report_Foreign => False);
         when Landin.Targets.Capabilities.Cortex_M0_ELF =>
            return (Switch_Bytes => 40, Prepared_Bytes => 40,
                    Entry_Bytes => 0, Report_Bytes => 0,
                    Report_Foreign => False);
         when Landin.Targets.Capabilities.No_Backend =>
            return (others => <>);
      end case;
   end Stack_Facts_Of;

   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Level    : Landin.Targets.Levels.Feature_Level;
      Options  : Landin.Optimization.Options;
      Assembly : out Ada.Strings.Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Debug : access constant Landin.Debugging.Information := null;
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Panic : access constant Landin.Panics.Plan := null) is
   begin
      if not Landin.Targets.Levels.Belongs_To (Level, Facts) then
         raise Compiler_Defect with "a level of another target's family";
      end if;
      case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.X86_64_ELF =>
            Landin.Backend.X86_64.Emit
              (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
               Hosted_Entry, Debug, Panic, Level);
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
           | Landin.Targets.Capabilities.Arm64_ELF =>
            Landin.Backend.Arm64.Emit
              (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
               Hosted_Entry, Debug, Panic, Level);
         when Landin.Targets.Capabilities.RV64_ELF =>
            Landin.Backend.RiscV.Emit
              (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
               Hosted_Entry, Debug, Panic, Level);
         when Landin.Targets.Capabilities.Cortex_M0_ELF =>
            Landin.Backend.Cortex_M.Emit
              (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
               Hosted_Entry, Debug, Firmware_Entry, Panic, Level);
         when Landin.Targets.Capabilities.No_Backend =>
            raise Compiler_Defect with "target has no assembly emitter";
      end case;
   end Emit;

end Landin.Backend.Dispatch;
