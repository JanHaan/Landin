with Ada.Strings.Unbounded;
with Landin.Platform;

package Landin.Commands.Response_Files is
   procedure Expand
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class;
      Result : out Landin.Platform.Path_List;
      Problem : out Ada.Strings.Unbounded.Unbounded_String);
end Landin.Commands.Response_Files;
