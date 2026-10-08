with Ada.Strings.Unbounded;
with Landin.Platform;

package Landin.Commands.Tracing is
   type Runner
     (Original : not null access constant Landin.Platform.Tool_Runner'Class;
      Transcript : not null access Ada.Strings.Unbounded.Unbounded_String)
      is limited new Landin.Platform.Tool_Runner with null record;

   overriding function Available (Host : Runner; Program : String)
      return Boolean;
   overriding procedure Run
     (Host : Runner; Program : String;
      Arguments : Landin.Platform.Path_List;
      Result : out Landin.Platform.Tool_Result;
      Capture : Landin.Platform.Capture_Mode := Landin.Platform.Merged);
   overriding procedure Prepare_Output
     (Host : Runner; Files : Landin.Platform.Filesystem'Class; Path : String);
   overriding function Output_Produced
     (Host : Runner; Files : Landin.Platform.Filesystem'Class; Path : String)
      return Boolean;
end Landin.Commands.Tracing;
