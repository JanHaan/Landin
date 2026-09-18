with Landin.Panics;
--  Native Darwin arm64 assembly from verified IR.
with Ada.Strings.Unbounded;

with Landin.Build_Reports;
with Landin.Debugging;
with Landin.Optimization;
with Landin.IR;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Targets;

package Landin.Backend.Arm64 is

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean;

   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Assembly : out Ada.Strings.Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Debug : access constant Landin.Debugging.Information := null;
      Panic : access constant Landin.Panics.Plan := null);

end Landin.Backend.Arm64;
