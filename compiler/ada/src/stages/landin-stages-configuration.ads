--  D139's target-selected declaration activity stage.

package Landin.Stages.Configuration is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome);

   --  D412: fold the compiler assertions configuration deferred because
   --  they measure a declared type's layout.  The checking stage calls
   --  this once its layouts and `offsetof` facts are recorded; it reports
   --  a false or ill-typed assertion and changes nothing else.
   procedure Check_Layout_Assertions (Whole : in out Compilation'Class);

end Landin.Stages.Configuration;
