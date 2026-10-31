--  `refine svd`: read a device's SVD and its selection policy, project
--  them, and replace the outputs (D558).
--
--  Replacement is preflighted, staged and verified before anything is
--  replaced, as the binding generator's is: every destination is checked
--  first, every new file is written beside its destination and read back,
--  and only then is each destination replaced, its old bytes kept beside
--  it until all are; a failure puts back what was replaced.  A file whose
--  bytes are already the new ones is left alone, and a file the previous
--  manifest named that this run no longer makes is removed with the rest.
--  This is recovery from a failure, not a snapshot for a concurrent
--  reader: nothing should read the outputs while they are replaced.

with Landin.Driver;
with Landin.Platform;

package Landin.Commands.Devices is

   procedure Import
     (Svd_Path, Policy_Path, Out_Dir : String;
      Host   : Landin.Platform.Filesystem'Class;
      Result : in out Landin.Driver.Outcome);

end Landin.Commands.Devices;
