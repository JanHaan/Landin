with Landin.Testing;

package Landin.Tests.Server_Suite is
   procedure Register (Into : in out Landin.Testing.Registry);

   --  Rewrite every session's `<-` lines and exit status with what the
   --  server sends now.  Only `--record` calls this.
   procedure Record_Sessions (Wrote : out Boolean);
end Landin.Tests.Server_Suite;
