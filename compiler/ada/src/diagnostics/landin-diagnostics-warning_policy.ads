--  Invocation policy applies after lawful source checking and before effects.
with Ada.Containers.Vectors;

package Landin.Diagnostics.Warning_Policy is
   type Base_Mode is (Recommended, All_Warnings, No_Warnings);
   type Control is (Warn, Allow, Deny);
   type Policy is private;

   function Defaults return Policy;
   procedure Set_Base (Item : in out Policy; Mode : Base_Mode);
   function Valid_Selector (Text : String) return Boolean;
   procedure Add
     (Item : in out Policy; Selector : String; Action : Control)
     with Pre => Valid_Selector (Selector);
   function Apply
     (Item : Policy; Report : Diagnostic_List) return Diagnostic_List;
   function Denied (Item : Policy; Report : Diagnostic_List) return Boolean;

private
   type Rule is record
      Every : Boolean := False;
      Code : Code_String := "?????";
      Action : Control := Warn;
   end record;
   package Rule_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Rule);
   type Policy is record
      Base : Base_Mode := Recommended;
      Rules : Rule_Vectors.Vector;
   end record;
end Landin.Diagnostics.Warning_Policy;
