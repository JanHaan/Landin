with Ada.Strings.Unbounded;

with Landin.Testing;

package Landin.Tests.Server_Suite is
   procedure Register (Into : in out Landin.Testing.Registry);

   --  Rewrite every session's `<-` lines with what the server sends now.
   --  Only `--record` calls this.  Said holds a line for each transcript
   --  that was left as it is, and Wrote is then False.
   procedure Record_Sessions
     (Wrote : out Boolean;
      Said  : out Ada.Strings.Unbounded.Unbounded_String);

   --  The same for one session, named as its directory under
   --  compiler/tests/server is, so adding or changing one session does not
   --  rewrite every other transcript.  Found is False when no session has
   --  that name.  Only `--record=server/NAME` calls this.
   --
   --  A recording replaces the messages of a session that ran, and nothing
   --  else.  A transcript that could not be run, one with no `exit:` line
   --  yet or a line that is none of its forms, is left as it is: its
   --  recording is empty, and written over the file it once emptied
   --  requests typed by hand that were in no commit.  A session that ended
   --  with another status than its `exit:` line names is left too: the
   --  status is the transcript's verdict, and the fixture recorder refuses
   --  to replace a verdict for the same reason.  Said then says why.
   procedure Record_Session
     (Name  : String;
      Found : out Boolean;
      Wrote : out Boolean;
      Said  : out Ada.Strings.Unbounded.Unbounded_String);
end Landin.Tests.Server_Suite;
