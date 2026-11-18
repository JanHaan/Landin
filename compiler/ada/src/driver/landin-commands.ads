--  The user-facing command interface. The driver remains the compilation
--  request boundary, including its compatibility spellings.
with Landin.Build_Identity;
with Landin.Driver;
with Landin.Platform;
with Landin.Targets.Selection;

package Landin.Commands is

   --  Shipped is the split commands this refine was built with, their
   --  names separated by single spaces (D1483); a case names its own.
   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Meter     : Landin.Platform.Resource_Meter'Class;
      Built_For : String := Landin.Targets.Selection.Build_Triplet;
      Terminal_Color : Boolean := False;
      Shipped   : String := Landin.Build_Identity.Split_Commands)
      return Landin.Driver.Outcome;

   --  D526: run what Execute compiled for `refine run`, after the caller
   --  has written its report, with the terminal and no limit; remove its
   --  directory, however it ends; and leave in Result the program's
   --  status, or 128 and the signal's number with a line naming it.  The
   --  report and output Execute gave are cleared, having been written.
   --  Nothing to run leaves Result as it is.
   procedure Launch
     (Result : in out Landin.Driver.Outcome;
      Host   : Landin.Platform.Filesystem'Class;
      Tools  : Landin.Platform.Tool_Runner'Class);

   --  Shares command parsing with Execute, so help never starts a server.
   function Is_Server
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class)
      return Boolean;

end Landin.Commands;
