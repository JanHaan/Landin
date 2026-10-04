--  Applying a report's fixes, which only a test does.
--
--  The compiler builds fixes and never applies one: an editor or a person
--  does that.  The harness applies them to prove that each is what it
--  claims, so the one routine that does it lives on the test side, where no
--  stage can come to depend on it.

with Landin.Diagnostics;
with Landin.Source;

package Landin.Testing.Fixes is

   --  Text with every edit that names Source applied.  The first fix of each
   --  diagnostic is used, except that Choice_Fix selects an alternative for
   --  Choice_Diagnostic when it is nonzero.  Edits are applied from
   --  the end of the text towards its start, so each one's offsets are the
   --  offsets of the text the compilation read.  Two edits from different
   --  diagnostics that overlap cannot both be applied, and Clashed says so.
   function Applied
     (Found   : Landin.Diagnostics.Diagnostic_List;
      Source  : Landin.Source.Source_Id;
      Text    : String;
      Clashed : out Boolean;
      Choice_Diagnostic : Natural := 0;
      Choice_Fix        : Positive := 1) return String;

   --  Whether the selected fixes edit Source.
   function Edits
     (Found  : Landin.Diagnostics.Diagnostic_List;
      Source : Landin.Source.Source_Id;
      Choice_Diagnostic : Natural := 0;
      Choice_Fix        : Positive := 1) return Boolean;

end Landin.Testing.Fixes;
