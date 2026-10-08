--  The user-facing command interface. The driver remains the compilation
--  request boundary, including its compatibility spellings.
with Landin.Driver;
with Landin.Platform;
with Landin.Targets.Selection;

package Landin.Commands is

   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Meter     : Landin.Platform.Resource_Meter'Class;
      Built_For : String := Landin.Targets.Selection.Build_Triplet;
      Terminal_Color : Boolean := False) return Landin.Driver.Outcome;

   --  Shares command parsing with Execute, so help never starts a server.
   function Is_Server
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class)
      return Boolean;

end Landin.Commands;
