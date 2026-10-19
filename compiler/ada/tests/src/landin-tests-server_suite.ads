with Landin.Testing;

package Landin.Tests.Server_Suite is
   procedure Register (Into : in out Landin.Testing.Registry);

   --  Rewrite every session's `<-` lines and exit status with what the
   --  server sends now.  Only `--record` calls this.
   procedure Record_Sessions (Wrote : out Boolean);

   --  The same for one session, named as its directory under
   --  compiler/tests/server is, so adding or changing one session does not
   --  rewrite every other transcript.  Found is False when no session has
   --  that name.  Only `--record=server/NAME` calls this.
   procedure Record_Session
     (Name : String; Found : out Boolean; Wrote : out Boolean);
end Landin.Tests.Server_Suite;
