with Landin.Targets;

--  D267: source namespace availability is independent of root selection.
package Landin.Modules.Availability is

   function Permitted
     (Logical : String; Facts : Landin.Targets.Target_Facts) return Boolean;

   function Requirement (Logical : String) return String;

end Landin.Modules.Availability;
