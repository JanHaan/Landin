with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Paths;

package body Landin.Library is

   package Unbounded renames Ada.Strings.Unbounded;

   function Is_Library_Import (Logical : String) return Boolean is
      Slash : constant Natural := Ada.Strings.Fixed.Index (Logical, "/");
      First : constant String :=
        (if Slash = 0 then Logical
         else Logical (Logical'First .. Slash - 1));
   begin
      return First in "core" | "hosted" | "platform";
   end Is_Library_Import;

   function Holds_Library
     (Host : Landin.Platform.Filesystem'Class; Directory : String)
      return Boolean
   is
      function Holds (Namespace : String) return Boolean
        is (Host.Is_Directory
              (Landin.Paths.Joined_Path (Directory, Namespace)));
   begin
      return Directory /= ""
        and then (Holds ("core") or else Holds ("hosted")
                  or else Holds ("platform"));
   end Holds_Library;

   --  The directory Path is in, or "" when Path is the top of the
   --  filesystem or names no directory at all.
   function Parent (Path : String) return String;

   function Parent (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      if Path = "/" or else Slash = 0 then
         return "";
      elsif Slash = Path'First then
         return "/";
      end if;
      return Path (Path'First .. Slash - 1);
   end Parent;

   function Located (Host : Landin.Platform.Filesystem'Class) return String
   is (Located_From (Host, Host.Executable_Directory));

   function Located_For_Split (Host : Landin.Platform.Filesystem'Class)
     return String
   is
      Commands : constant String := Host.Executable_Directory;
      Prefix : constant String :=
        (if Commands = "" then "" else Parent (Parent (Commands)));
   begin
      if Prefix = "" then
         return "";
      end if;
      return Located_From (Host, Landin.Paths.Joined_Path (Prefix, "bin"));
   end Located_For_Split;

   function Located_From
     (Host : Landin.Platform.Filesystem'Class; Binaries : String)
      return String is
   begin
      if Binaries = "" then
         return "";
      end if;

      --  PREFIX/bin/refine with PREFIX/lib/landin.
      declare
         Prefix : constant String := Parent (Binaries);
      begin
         if Prefix /= "" then
            declare
               Installed : constant String :=
                 Landin.Paths.Joined_Path (Prefix, "lib/landin");
            begin
               if Holds_Library (Host, Installed) then
                  return Installed;
               end if;
            end;
         end if;
      end;

      --  REPO/compiler/ada/build/TAG/MODE/bin/refine with the library at
      --  REPO, which must also hold the compiler's own sources: a `core`
      --  six directories up from some other executable is not this one's.
      declare
         Repository : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String (Binaries);
      begin
         for Level in 1 .. 6 loop
            Repository := Unbounded.To_Unbounded_String
              (Parent (Unbounded.To_String (Repository)));
            if Unbounded.Length (Repository) = 0 then
               return "";
            end if;
         end loop;
         declare
            Top : constant String := Unbounded.To_String (Repository);
         begin
            if Holds_Library (Host, Top)
              and then Host.Is_Directory
                (Landin.Paths.Joined_Path (Top, "compiler/ada"))
            then
               return Top;
            end if;
         end;
      end;
      return "";
   end Located_From;

   function Looked_In (Host : Landin.Platform.Filesystem'Class)
     return String
   is
      Binaries : constant String := Host.Executable_Directory;
      Prefix : constant String :=
        (if Binaries = "" then "" else Parent (Binaries));
      Repository : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (Binaries);
   begin
      if Binaries = "" then
         return "refine could not tell which directory it was started from";
      end if;
      for Level in 1 .. 6 loop
         Repository := Unbounded.To_Unbounded_String
           (Parent (Unbounded.To_String (Repository)));
      end loop;
      return "refine looked in "
        & (if Prefix = "" then "no prefix above " & Binaries
           else Landin.Paths.Joined_Path (Prefix, "lib/landin"))
        & (if Unbounded.Length (Repository) = 0 then ""
           else " and in " & Unbounded.To_String (Repository)
             & ", the checkout a build tree's refine is in");
   end Looked_In;

end Landin.Library;
