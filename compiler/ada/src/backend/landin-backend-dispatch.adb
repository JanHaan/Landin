with Landin.Backend.X86_64;
with Landin.Backend.Arm64;
with Landin.Targets.Capabilities;

package body Landin.Backend.Dispatch is

   function Frame_Limit (Facts : Landin.Targets.Target_Facts) return String is
     (case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.Linux_X86_64_ELF =>
            "signed 32-bit offsets this backend addresses",
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O =>
            "signed 32-bit frame budget of the arm64 backend",
         when Landin.Targets.Capabilities.No_Backend =>
            "frame encoding of an unavailable backend");

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean is
   begin
      case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.Linux_X86_64_ELF =>
            return Landin.Backend.X86_64.Frame_Is_Addressable
              (Of_Unit, Item, Facts, Options);
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O =>
            return Landin.Backend.Arm64.Frame_Is_Addressable
              (Of_Unit, Item, Facts, Options);
         when Landin.Targets.Capabilities.No_Backend => return False;
      end case;
   end Frame_Is_Addressable;

   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Assembly : out Ada.Strings.Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Debug : access constant Landin.Debugging.Information := null) is
   begin
      case Landin.Targets.Capabilities.Backend_For (Facts) is
         when Landin.Targets.Capabilities.Linux_X86_64_ELF =>
            Landin.Backend.X86_64.Emit
              (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
               Hosted_Entry, Debug);
         when Landin.Targets.Capabilities.Darwin_Arm64_Mach_O =>
            Landin.Backend.Arm64.Emit
              (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
               Hosted_Entry, Debug);
         when Landin.Targets.Capabilities.No_Backend =>
            raise Compiler_Defect with "target has no assembly emitter";
      end case;
   end Emit;

end Landin.Backend.Dispatch;
