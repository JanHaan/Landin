with Landin.Diagnostics.Catalogue;

package body Landin.Diagnostics.Warning_Policy is
   package C renames Landin.Diagnostics.Catalogue;
   use type C.Disposition;

   function Defaults return Policy is (others => <>);

   procedure Set_Base (Item : in out Policy; Mode : Base_Mode) is
   begin
      Item.Base := Mode;
   end Set_Base;

   function Valid_Selector (Text : String) return Boolean is
     (Text = "all" or else
        (Is_Valid_Code (Text) and then C.Holds (Text)
         and then C.State (C.Named (Text)) = C.Live
         and then C.Level (C.Named (Text)) = Warning));

   procedure Add
     (Item : in out Policy; Selector : String; Action : Control)
   is
      Extra : Rule := (Every => Selector = "all", Action => Action,
                       others => <>);
   begin
      if not Extra.Every then
         Extra.Code := Selector;
      end if;
      Item.Rules.Append (Extra);
   end Add;

   function Selected (Item : Policy; Code : Code_String) return Control;
   function Selected (Item : Policy; Code : Code_String) return Control is
      Result : Control :=
        (case Item.Base is
            when All_Warnings => Warn,
            when No_Warnings => Allow,
            when Recommended =>
              (if C.Holds (Code) and then
                 C.Warning_Enabled_By_Default (C.Named (Code))
               then Warn else Allow));
   begin
      for Extra of Item.Rules loop
         if Extra.Every or else Extra.Code = Code then
            Result := Extra.Action;
         end if;
      end loop;
      return Result;
   end Selected;

   function Apply
     (Item : Policy; Report : Diagnostic_List) return Diagnostic_List
   is
      Result : Diagnostic_List;
   begin
      for Index in 1 .. Count (Report) loop
         declare
            Original : constant Diagnostic := Get (Report, Index);
            Action : constant Control := Selected (Item, Code (Original));
            Kept : Diagnostic := Original;
         begin
            if Level (Original) /= Warning or else Action /= Allow then
               if Level (Original) = Warning and then Action = Deny then
                  Kept := With_Severity (Original, Error);
                  Add_Note (Kept,
                    "warning was denied by command-line policy");
               end if;
               Result.Append (Kept);
            end if;
         end;
      end loop;
      return Result;
   end Apply;

   function Denied (Item : Policy; Report : Diagnostic_List) return Boolean is
   begin
      for Index in 1 .. Count (Report) loop
         declare
            Original : constant Diagnostic := Get (Report, Index);
         begin
            if Level (Original) = Warning
              and then Selected (Item, Code (Original)) = Deny
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Denied;
end Landin.Diagnostics.Warning_Policy;
