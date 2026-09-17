--  Compiler-owned reset and linker inputs. No filesystem or tool effects.
package Landin.Backend.Firmware is
   function Materialization_Fits (Of_Unit : Landin.IR.Unit) return Boolean;
   function Startup (Entry_Symbol : String) return String;
   function Linker_Script return String;
end Landin.Backend.Firmware;
