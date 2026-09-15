with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Targets.Capabilities;

package body Landin.Backend.Toolchain is

   use type Landin.Targets.Capabilities.Backend_Kind;

   function Identity_Section
     (Build_Id : String; Facts : Landin.Targets.Target_Facts) return String
   is
      LF : constant Character := Character'Val (10);
   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
        = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         --  A non-filename section contributing to Apple's linked UUID,
         --  retained even when optional debugger information is stripped.
         return ".section __TEXT,__landin_id,regular,no_dead_strip" & LF
           & ".ascii """ & Build_Id & """" & LF;
      end if;
      return "";
   end Identity_Section;

   function Debug_Artifacts
     (Output : String; Facts : Landin.Targets.Target_Facts;
      Host : Landin.Platform.Filesystem'Class)
      return Landin.Platform.Path_List
   is
      Result : Landin.Platform.Path_List;
      Slash : constant Natural := Ada.Strings.Fixed.Index
        (Output, "/", Ada.Strings.Backward);
      Name : constant String := Output
        ((if Slash = 0 then Output'First else Slash + 1) .. Output'Last);
      procedure Existing (Path : String);
      procedure Existing (Path : String) is
      begin
         if Host.Exists (Path) then
            Result.Append (Path);
         end if;
      end Existing;
   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
        = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         Result.Append (Output & ".o");
         Result.Append (Output & ".dSYM");
         --  Existing leaves may be hard links to source outside the bundle.
         --  Missing nested parents have no file identity; source ancestors
         --  are checked separately before any output effect.
         Existing (Output & ".dSYM/Contents/Info.plist");
         Existing (Output & ".dSYM/Contents/Resources/DWARF/" & Name);
         Existing (Output & ".dSYM/Contents/Resources/Relocations/aarch64/"
                   & Name & ".yml");
      end if;
      return Result;
   end Debug_Artifacts;

   function Debug_Overwrites
     (Output, Source : String; Facts : Landin.Targets.Target_Facts;
      Host : Landin.Platform.Filesystem'Class) return Boolean
   is
   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
        = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         --  dsymutil owns the whole directory. Compare source ancestors
         --  through the host namespace, including symlink aliases.
         for Slash in Source'Range loop
            if Source (Slash) = '/' and then Slash > Source'First
              and then Host.Paths_Overlap
                (Output & ".dSYM", Source (Source'First .. Slash - 1))
            then
               return True;
            end if;
         end loop;
      end if;
      return False;
   end Debug_Overwrites;

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
      Facts : Landin.Targets.Target_Facts;
      Full_Debug : Boolean := False)
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
         if Full_Debug then
            --  Apple Clang retains the object and invokes dsymutil after
            --  linking. The resulting dSYM carries the executable's UUID.
            Landin.Platform.Add (List, "-gdwarf-4");
            Landin.Platform.Add (List, "-x");
            Landin.Platform.Add (List, "assembler");
            Landin.Platform.Add (List, "-save-temps=obj");
         end if;
      end if;
      Landin.Platform.Add (List, File_Operand (Assembly));
      if Full_Debug and then
        Landin.Targets.Capabilities.Backend_For (Facts)
          = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
      then
         Landin.Platform.Add (List, "-x");
         Landin.Platform.Add (List, "none");
      end if;
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
