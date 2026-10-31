--  Compiler-owned reset and linker inputs. No filesystem or tool effects.
package Landin.Backend.Firmware is
   function Startup
     (Entry_Symbol : String; Returned : String := "udf #1";
      Debug : Boolean := False) return String;
   function Linker_Script return String;
end Landin.Backend.Firmware;
