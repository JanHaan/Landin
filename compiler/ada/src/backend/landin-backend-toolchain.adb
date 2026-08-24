with Landin.Targets.Capabilities;

package body Landin.Backend.Toolchain is

   function Driver_For
     (Facts : Landin.Targets.Target_Facts;
      Named : String) return String
   is
      Triplet : constant String :=
        Landin.Targets.Capabilities.Triplet (Facts);
   begin
      if Named /= "" then
         return Named;
      elsif Triplet = "" then
         return "";
      else
         return Triplet & "-gcc";
      end if;
   end Driver_For;

   function Link_Arguments
     (Assembly : String;
      Output   : String;
      Linker   : String) return Landin.Platform.Path_List
   is
      List : Landin.Platform.Path_List;
   begin
      Landin.Platform.Add (List, Assembly);
      Landin.Platform.Add (List, "-o");
      Landin.Platform.Add (List, Output);

      if Linker /= "" then
         Landin.Platform.Add (List, "-fuse-ld=" & Linker);
      end if;

      return List;
   end Link_Arguments;

end Landin.Backend.Toolchain;
