--  D139's target-selected declaration activity stage.

package Landin.Stages.Configuration is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome);

end Landin.Stages.Configuration;
