with Landin.Panics;
--  Select concrete emission without exposing target choices to the driver.
with Ada.Strings.Unbounded;

with Landin.Build_Reports;
with Landin.Debugging;
with Landin.Optimization;
with Landin.IR;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Targets;
with Landin.Targets.Levels;

package Landin.Backend.Dispatch is

   function Frame_Limit (Facts : Landin.Targets.Target_Facts) return String;

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean;

   function Frame_Fits_Firmware_Stack
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts) return Boolean;

   --  D447's depth report (D467): what the code a backend emits outside
   --  any routine of the program takes of a stack.  Switch_Bytes is what a
   --  stack switch takes on the leaving stack below the switching
   --  routine's own, the call to the switch routine included; the limit is
   --  checked before it.  Prepared_Bytes is the first frame
   --  `compiler.stack_prepare` lays at the top of a stack, which the first
   --  switch onto it pops.  Entry_Bytes is how far below that top the
   --  entry's caller stands when the start routine calls it, so a prepared
   --  stack holds the larger of Prepared_Bytes and Entry_Bytes plus the
   --  entry's depth.  Report_Bytes is what D361's default report takes
   --  when a failed check calls it, and Report_Foreign that it calls the C
   --  library's `write`, whose stack is not known here: on the stack that
   --  failed, unless the program prepares a stack (D491).  Limit_Margin is
   --  how far above a prepared stack's base its limit stands, and
   --  Unchecked the largest call-free frame or call area no check covers
   --  (D471, D472), and Handler_Entry what the margin pays before a
   --  selected handler's own frames (D474); all three are
   --  Landin.Backend's.  On Cortex-M0 a
   --  failed check with no handler is an undefined instruction, whose
   --  exception frame D461 charges to every stack an exception can take.
   type Stack_Facts is record
      Switch_Bytes   : Landin.Targets.Byte_Count := 0;
      Prepared_Bytes : Landin.Targets.Byte_Count := 0;
      Entry_Bytes    : Landin.Targets.Byte_Count := 0;
      Report_Bytes   : Landin.Targets.Byte_Count := 0;
      Report_Foreign : Boolean := False;
      Limit_Margin   : Landin.Targets.Byte_Count := 0;
      Unchecked      : Landin.Targets.Byte_Count := 0;
      Handler_Entry  : Landin.Targets.Byte_Count := 0;
   end record;

   function Stack_Facts_Of
     (Facts : Landin.Targets.Target_Facts) return Stack_Facts;

   --  D471: whether the program holds a `compiler.stack_prepare`, so that
   --  its routines check their frames against a stack's limit and its
   --  selected handler runs on a prepared stack's margin (D474).
   function Prepares_Stacks (Of_Unit : Landin.IR.Unit) return Boolean;

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
      Panic : access constant Landin.Panics.Plan := null)
     with Pre => Landin.Targets.Levels.Belongs_To (Level, Facts);

end Landin.Backend.Dispatch;
