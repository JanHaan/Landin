with Landin.Targets.Capabilities;

package body Landin.Backend.Toolchain is

   use type Landin.Targets.Capabilities.Backend_Kind;

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
      Linker   : String;
      Build_Id : String := "";
      Libraries : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments;
      Facts : Landin.Targets.Target_Facts)
      return Landin.Platform.Path_List
   is
      List : Landin.Platform.Path_List;

      function File_Operand (Path : String) return String;

      function File_Operand (Path : String) return String is
      begin
         --  A driver interprets leading '-' as an option and leading '@'
         --  as a response file, even for a separately passed argv entry.
         --  './' keeps the same relative file identity on the native host.
         if Path'Length > 0 and then Path (Path'First) in '-' | '@' then
            return "./" & Path;
         end if;
         return Path;
      end File_Operand;
   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
        /= Landin.Targets.Capabilities.Linux_X86_64_ELF
      then
         raise Compiler_Defect with "target has no linker argument policy";
      end if;
      Landin.Platform.Add (List, File_Operand (Assembly));
      --  [1590] selects archives, while the hosted driver retains control
      --  of libc and startup linkage. Repeats matter to archive resolution.
      for Library of Libraries loop
         Landin.Platform.Add (List, "-l:lib" & Library & ".a");
      end loop;
      Landin.Platform.Add (List, "-o");
      Landin.Platform.Add (List, File_Operand (Output));

      if Linker /= "" then
         Landin.Platform.Add (List, "-fuse-ld=" & Linker);
      end if;

      if Build_Id /= "" then
         Landin.Platform.Add (List, "-Wl,--build-id=0x" & Build_Id);
      end if;

      return List;
   end Link_Arguments;

end Landin.Backend.Toolchain;
