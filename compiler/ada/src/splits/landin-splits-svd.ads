--  `refine svd`, the split command `refine-svd` (D1383): read a device's
--  SVD and its selection policy, project them, and replace the outputs
--  (D558).
--
--  The shared Platform transaction snapshots the generated and stale set,
--  validates staging, and preserves every old version until group success.
--  Conflicts preserve foreign entries and report retained recovery. Equal
--  outputs retain their inode; group visibility is not atomic.

with Landin.Outcomes;
with Landin.Platform;

package Landin.Splits.Svd is

   --  The command's whole run, as its main and the fake host's cases call
   --  it: Arguments are the words after `svd`.
   function Execute
     (Arguments      : Landin.Platform.Path_List;
      Host           : Landin.Platform.Filesystem'Class;
      Tools          : Landin.Platform.Tool_Runner'Class;
      Built_For      : String := "";
      Terminal_Color : Boolean := False) return Landin.Outcomes.Outcome;

   procedure Import
     (Svd_Path, Policy_Path, Out_Dir : String;
      Host   : Landin.Platform.Filesystem'Class;
      Result : in out Landin.Outcomes.Outcome;
      Protected_Inputs : Landin.Platform.Path_List :=
        Landin.Platform.Path_Vectors.Empty_Vector;
      Protected_Identities : Landin.Platform.Identity_List :=
        Landin.Platform.Identity_Vectors.Empty_Vector);

end Landin.Splits.Svd;
