with Landin.Outcomes;

package Landin.Presentation is
   type Style is (Human, Short, JSON);
   procedure Render
     (Result : in out Landin.Outcomes.Outcome;
      Format : Style;
      Color : Boolean);
end Landin.Presentation;
