--  The selected constrained Cortex-M image, in target bytes.
with Landin.Targets.Levels;
package Landin.Targets.Firmware is
   Flash_Base : constant Byte_Count := 0;
   Flash_Size : constant Byte_Count := 32 * 1024;
   RAM_Base   : constant Byte_Count := 16#2000_0000#;
   RAM_Size   : constant Byte_Count := 16 * 1024;
   Stack_Size : constant Byte_Count := 4 * 1024;
   Vector_Count : constant := 48;

   --  D537: the reference profile's capacities as the image budget takes
   --  them.  Its flash holds every written image and its RAM every mutable
   --  one, which reset copies there; zero images are bounded by the 32-bit
   --  address space, and the linker places them in the RAM left over.
   function Budget return Image_Budget;

   --  The profile as a refusal names it, after the target's name.
   Profile_Name : constant String := "constrained reference profile";

   function Assembly_Error
     (Text : String; Naked : Boolean;
      Level : Landin.Targets.Levels.Feature_Level) return String;
end Landin.Targets.Firmware;
