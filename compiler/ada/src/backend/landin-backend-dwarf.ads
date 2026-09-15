--  Optional DWARF4 serialization of existing source, IR and allocation facts.
--  No format-specific facts flow back into those authorities.  Version four
--  supplies the required types and location lists without a second indexed
--  address/string representation; source matching remains D192's exact map.
with Landin.Debugging;
with Landin.Optimization;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Provenance;

package Landin.Backend.Dwarf is

   function Quoted (Bytes : String) return String;
   function Label_Name
     (Prefix, Kind : String; Item : Landin.IR.Item_Id;
      Index : Natural := 0) return String;
   function Source_Line
     (Info : Landin.Debugging.Information;
      Site : Landin.Provenance.Origin) return String;
   function Preamble
     (Info : Landin.Debugging.Information; Prefix : String;
      Mach_O : Boolean := False) return String;
   generic
      type Placement (<>) is private;
      with function Make
        (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
         Facts : Landin.Targets.Target_Facts;
         Options : Landin.Optimization.Options) return Placement;
      with function Frame_For
        (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
         Facts : Landin.Targets.Target_Facts; Plan : Placement;
         Options : Landin.Optimization.Options) return Frame;
      with function Slot_Expression
        (Plan : Placement; Layout : Frame; Slot : Landin.IR.Slot_Id;
         Indirect, Address_Only : Boolean) return String;
      Frame_Register : Natural;
      Mach_O : Boolean;
   function Sections
     (Of_Unit : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names : Landin.Source.Names.Table;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Info : Landin.Debugging.Information;
      Prefix : String;
      Symbol : not null access function
        (Item : Landin.IR.Item_Id) return String) return String;

end Landin.Backend.Dwarf;
