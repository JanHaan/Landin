--  A language server: the compiler's third client, after `refine` and the
--  test program.
--
--  It reads what an editor sends over a channel, keeps the buffers the
--  editor holds over the host's filesystem, and answers from a compilation
--  of the module each buffer belongs to, built by the same loader and the
--  same stages `refine` runs.  One compilation is alive at a time and is
--  freed before the next is made, which is why a compilation owns its
--  storage and gives it back whole.
--
--  The children say how: what a broken routine body is analysed as, how a
--  byte offset becomes an editor's position, how messages are framed, and
--  what each request is answered with.

package Landin.Server is

   pragma Pure;

end Landin.Server;
