with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Driver.Loading;

package body Landin.Driver.Library is

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
     is (Directory /= ""
         and then Host.Is_Directory
           (Landin.Driver.Loading.Joined_Path (Directory, "core")));

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
   is
      Binaries : constant String := Host.Executable_Directory;
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
                 Landin.Driver.Loading.Joined_Path (Prefix, "lib/landin");
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
                (Landin.Driver.Loading.Joined_Path (Top, "compiler/ada"))
            then
               return Top;
            end if;
         end;
      end;
      return "";
   end Located;

end Landin.Driver.Library;
