--  Compilation-wide optimization axes.  These are not fixed source
--  configuration, build modes, or permission to omit runtime checks.
package Landin.Optimization is

   type Objective is (None, Size, Speed);
   type Specialization_Mode is (Off, Auto, All_Eligible);

   type Options is record
      Optimize   : Objective := Size;
      Specialize : Specialization_Mode := Auto;
   end record;

   Default_Options : constant Options := (Size, Auto);
   Reference_Options : constant Options := (None, Off);

   function Spelling (Value : Objective) return String;
   function Spelling (Value : Specialization_Mode) return String;

   --  Exact lowercase request values only.  Failure supplies the default
   --  value but Accepted=False; the driver must reject the request.
   procedure Parse
     (Text : String; Value : out Objective; Accepted : out Boolean);
   procedure Parse
     (Text : String; Value : out Specialization_Mode;
      Accepted : out Boolean);

end Landin.Optimization;
