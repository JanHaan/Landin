with Landin.Panics;
--  Native RV64 Linux LP64D assembly from verified IR.
with Ada.Strings.Unbounded;

with Landin.Build_Reports;
with Landin.Debugging;
with Landin.Optimization;
with Landin.IR;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Targets;
with Landin.Targets.Levels;

package Landin.Backend.RiscV is

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
      Panic : access constant Landin.Panics.Plan := null;
      Level : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Landin.Targets.Linux_RV64));

end Landin.Backend.RiscV;
