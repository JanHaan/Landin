with Ada.Strings.Unbounded;
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
      elsif Landin.Targets.Capabilities.Backend_For (Facts)
        = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         return "/usr/bin/clang";
      elsif Triplet = "" then
         return "";
      else
         return Triplet & "-gcc";
      end if;
   end Driver_For;

   procedure Resolve_Libraries
     (Facts : Landin.Targets.Target_Facts;
      Driver : String;
      Host : Landin.Platform.Filesystem'Class;
      Tools : Landin.Platform.Tool_Runner'Class;
      Libraries : in out Landin.Platform.Path_List;
      Result : out Landin.Platform.Tool_Result;
      Ready : out Boolean)
   is
      use type Landin.Platform.Termination;
      Resolved : Landin.Platform.Path_List;
   begin
      Ready := True;
      Result := (others => <>);
      if Landin.Targets.Capabilities.Backend_For (Facts)
        /= Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         return;
      end if;
      for Library of Libraries loop
         Tools.Run
           (Driver, Landin.Platform.Arguments
              ("-print-file-name=lib" & Library & ".a"), Result,
            Landin.Platform.Output_Only);
         if Result.Ended /= Landin.Platform.Exited
           or else Result.Exit_Code /= 0
         then
            Ready := False;
            return;
         end if;
         declare
            Path : constant String :=
              Ada.Strings.Unbounded.To_String (Result.Output);
            Last : Natural := Path'Last;
         begin
            while Last >= Path'First
              and then Path (Last) in ASCII.LF | ASCII.CR
            loop
               Last := Last - 1;
            end loop;
            if Last < Path'First
              or else not Host.Exists (Path (Path'First .. Last))
              or else Host.Is_Directory (Path (Path'First .. Last))
            then
               Ready := False;
               Result.Exit_Code := 1;
               Result.Output := Ada.Strings.Unbounded.To_Unbounded_String
                 ("cannot resolve Darwin archive lib" & Library & ".a");
               return;
            end if;
            Resolved.Append (Path (Path'First .. Last));
         end;
      end loop;
      Libraries := Resolved;
   end Resolve_Libraries;

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
        = Landin.Targets.Capabilities.No_Backend
      then
         raise Compiler_Defect with "target has no linker argument policy";
      end if;
      if Landin.Targets.Capabilities.Backend_For (Facts)
        = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         Landin.Platform.Add (List, "-arch");
         Landin.Platform.Add (List, "arm64");
      end if;
      Landin.Platform.Add (List, File_Operand (Assembly));
      --  [1590] selects archives, while the hosted driver retains control
      --  of libc and startup linkage. Repeats matter to archive resolution.
      for Library of Libraries loop
         Landin.Platform.Add
           (List, (if Landin.Targets.Capabilities.Backend_For (Facts)
                     = Landin.Targets.Capabilities.Linux_X86_64_ELF
                   then "-l:lib" & Library & ".a"
                   else File_Operand (Library)));
      end loop;
      Landin.Platform.Add (List, "-o");
      Landin.Platform.Add (List, File_Operand (Output));

      if Linker /= "" then
         Landin.Platform.Add (List, "-fuse-ld=" & Linker);
      end if;

      if Build_Id /= "" and then
        Landin.Targets.Capabilities.Backend_For (Facts)
          = Landin.Targets.Capabilities.Linux_X86_64_ELF
      then
         Landin.Platform.Add (List, "-Wl,--build-id=0x" & Build_Id);
      end if;

      return List;
   end Link_Arguments;

end Landin.Backend.Toolchain;
