--  `refine svd`: read a device's SVD and its selection policy, project
--  them, and replace the outputs (D558).
--
--  The shared Platform transaction snapshots the generated and stale set,
--  validates staging, and preserves every old version until group success.
--  Conflicts preserve foreign entries and report retained recovery. Equal
--  outputs retain their inode; group visibility is not atomic.

with Landin.Driver;
with Landin.Platform;

package Landin.Commands.Devices is

   procedure Import
     (Svd_Path, Policy_Path, Out_Dir : String;
      Host   : Landin.Platform.Filesystem'Class;
      Result : in out Landin.Driver.Outcome;
      Protected_Inputs : Landin.Platform.Path_List :=
        Landin.Platform.Path_Vectors.Empty_Vector;
      Protected_Identities : Landin.Platform.Identity_List :=
        Landin.Platform.Identity_Vectors.Empty_Vector);

end Landin.Commands.Devices;
