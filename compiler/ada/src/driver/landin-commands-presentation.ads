with Landin.Driver;

package Landin.Commands.Presentation is
   type Style is (Human, Short, JSON);
   procedure Render
     (Result : in out Landin.Driver.Outcome;
      Format : Style;
      Color : Boolean);
end Landin.Commands.Presentation;
