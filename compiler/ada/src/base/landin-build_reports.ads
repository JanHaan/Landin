--  Deterministic compiler evidence, not source diagnostics.  Producers append
--  actual outcomes in increasing stable identity order, independently for
--  each section.  Counts of instructions are not assembled object bytes.
private with Ada.Containers.Indefinite_Vectors;
private with Ada.Containers.Vectors;
with Landin.IR;
with Landin.Layouts;
with Landin.Optimization;
with Landin.Targets;
with Landin.Targets.Layouts;

package Landin.Build_Reports is

   type Specialization_Action is (Declined, Specialized);
   type Decision_Reason is
     (Disabled, No_Static_Dispatch, Unknown_Evidence, Address_Exposed,
      Single_Instance, Forced, Profitable, Cost_Threshold, Unsupported_Proof);

   type Specialization_Decision is record
      Item              : Landin.IR.Item_Id := Landin.IR.No_Item;
      Template          : Landin.IR.Declaration_Id := Landin.IR.No_Declaration;
      Instance_Position : Natural := 0;
      Action            : Specialization_Action := Declined;
      Reason            : Decision_Reason := No_Static_Dispatch;
      Entry_Calls       : Natural := 0;
      Loop_Depth        : Natural := 0;
      Represented_Bytes : Landin.Targets.Byte_Count := 0;
      Benefit           : Natural := 0;
      Estimated_Growth  : Natural := 0;
      Direct_Calls_Made : Natural := 0;
      Retains_Evidence_ABI : Boolean := True;
      Retains_Fallback  : Boolean := True;
   end record;

   type Routine_Statistics is record
      Item              : Landin.IR.Item_Id := Landin.IR.No_Item;
      --  No_Item means an independently emitted body; otherwise this is
      --  the earlier stable body identity actually shared by the symbol.
      Shared_With       : Landin.IR.Item_Id := Landin.IR.No_Item;
      Frame_Bytes       : Landin.Targets.Byte_Count := 0;
      Spill_Bytes       : Landin.Targets.Byte_Count := 0;
      Save_Bytes        : Landin.Targets.Byte_Count := 0;
      Register_Count    : Natural := 0;
      Spill_Count       : Natural := 0;
      Instructions      : Natural := 0;
      Stack_Loads       : Natural := 0;
      Stack_Stores      : Natural := 0;
      Direct_Calls      : Natural := 0;
      Indirect_Calls    : Natural := 0;
   end record;

   type Report is tagged private;
   procedure Clear (Into : in out Report);
   procedure Append
     (Into : in out Report; Decision : Specialization_Decision);
   procedure Append
     (Into : in out Report; Statistics : Routine_Statistics);
   procedure Append_Layout
     (Into : in out Report; Nominal_Position : Positive;
      Policy : Landin.Layouts.Policy; Placement : Landin.Targets.Layouts.Plan);

   function Specialization_Count (Of_Report : Report) return Natural;
   function Nth_Specialization
     (Of_Report : Report; Index : Positive) return Specialization_Decision;
   function Routine_Count (Of_Report : Report) return Natural;
   function Nth_Routine
     (Of_Report : Report; Index : Positive) return Routine_Statistics;
   function Layout_Count (Of_Report : Report) return Natural;
   function Layout_Position
     (Of_Report : Report; Index : Positive) return Positive;
   function Layout_Policy
     (Of_Report : Report; Index : Positive) return Landin.Layouts.Policy;
   function Layout_Plan
     (Of_Report : Report; Index : Positive) return Landin.Targets.Layouts.Plan;

   function Spelling (Value : Specialization_Action) return String;
   function Spelling (Value : Decision_Reason) return String;

   --  Pure renderer.  No paths, clocks, addresses or hash iteration.  Source
   --  filename/origin adapters may be added by integration without changing
   --  the producer record contracts or mistaking estimates for measurements.
   function JSON
     (Of_Report : Report;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return String;

private

   package Decision_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Specialization_Decision);
   package Statistics_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Routine_Statistics);
   type Layout_Record (Count : Natural) is record
      Position : Positive;
      Policy : Landin.Layouts.Policy;
      Placement : Landin.Targets.Layouts.Plan (Count);
   end record;
   package Layout_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Layout_Record);

   type Report is tagged record
      Decisions : Decision_Vectors.Vector;
      Routines : Statistics_Vectors.Vector;
      Layouts : Layout_Vectors.Vector;
   end record;

end Landin.Build_Reports;
