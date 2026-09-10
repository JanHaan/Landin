--  Optional DWARF4 serialization of existing source, IR and allocation facts.
--  No format-specific facts flow back into those authorities.  Version four
--  supplies the required types and location lists without a second indexed
--  address/string representation; source matching remains D192's exact map.
with Landin.Backend.X86_64.Allocation;
with Landin.Provenance;

package Landin.Backend.X86_64.Dwarf is

   function Quoted (Bytes : String) return String;
   function Label_Name
     (Prefix, Kind : String; Item : Landin.IR.Item_Id;
      Index : Natural := 0) return String;
   function Register_Number
     (Register : Allocation.Saved_Register) return Natural;
   function Source_Line
     (Info : Landin.Debugging.Information;
      Site : Landin.Provenance.Origin) return String;
   function Preamble
     (Info : Landin.Debugging.Information; Prefix : String) return String;
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

end Landin.Backend.X86_64.Dwarf;
