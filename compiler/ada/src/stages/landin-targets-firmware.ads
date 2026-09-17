--  The selected constrained Cortex-M0 image, in target bytes.
package Landin.Targets.Firmware is
   Flash_Base : constant Byte_Count := 0;
   Flash_Size : constant Byte_Count := 32 * 1024;
   RAM_Base   : constant Byte_Count := 16#2000_0000#;
   RAM_Size   : constant Byte_Count := 16 * 1024;
   Stack_Size : constant Byte_Count := 4 * 1024;
   Vector_Count : constant := 48;

   function Assembly_Error (Text : String; Naked : Boolean) return String;
end Landin.Targets.Firmware;
