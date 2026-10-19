--  The repository's own test harness.
--
--  There is no third-party test framework here and there will not be one:
--  the compiler's test suite is part of the compiler, and a harness small
--  enough to read is a harness that can be trusted to be deterministic.
--
--  A case registers a name and a procedure.  Registration order does not
--  matter: cases run sorted by suite and name, so the transcript of a run
--  is the same on every host.

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Landin.Testing is

   type Context is limited private;

   procedure Check
     (Item : in out Context; Condition : Boolean; Description : String);

   procedure Check_Equal
     (Item : in out Context; Actual, Expected : String; Description : String);

   procedure Check_Equal
     (Item : in out Context; Actual, Expected : Integer; Description : String);

   procedure Fail (Item : in out Context; Description : String);

   --  Take one context's results into another, for work that was split
   --  across workers and has to read afterwards as though it were not.
   --  A case that runs its fixtures in parallel gives each worker its own
   --  context and absorbs them in fixture order, so the checks, the
   --  failures and the failure text are what a single-file run produced.
   --  Merging out of order would change the transcript, which is the one
   --  thing the harness promises is the same on every host.
   procedure Absorb (Into : in out Context; From : Context);

   function Checks (Item : Context) return Natural;
   function Failures (Item : Context) return Natural;
   function Failure_Text (Item : Context) return String;

   type Case_Body is access procedure (Item : in out Context);

   type Registry is limited private;

   --  Raises Compiler_Defect on a duplicate (Suite, Name): two cases with
   --  one name is a harness defect, and silently running one of them is how
   --  a suite starts lying about its coverage.
   --
   --  A Divided case shares its work out across the shards of a sharded
   --  run, below, rather than belonging to one of them.
   procedure Register
     (Into    : in out Registry;
      Suite   : String;
      Name    : String;
      Run     : not null Case_Body;
      Divided : Boolean := False);

   function Is_Registered
     (In_Registry : Registry; Suite : String; Name : String) return Boolean;

   --  True when at least one case is registered under this suite name.
   --  The test program asserts its own inventory with it: a suite that
   --  stops being registered has to make a run red rather than make it
   --  smaller.
   function Has_Suite (In_Registry : Registry; Suite : String) return Boolean;

   --  Distinct suite names, independently of case count and ordering.
   function Suite_Count (In_Registry : Registry) return Natural;

   function Case_Count (In_Registry : Registry) return Natural;

   --  A run divided across processes, so a gate whose runners have a few
   --  CPUs each can run the inventory on several at once.  Shard Index of
   --  Count runs each ordinary case whose place among the ordinary cases,
   --  sorted as a run sorts them, is Index - 1 modulo Count.  A Divided
   --  case runs in every shard instead, over its own share of its work:
   --  the items In_Share answers True for.  So the shards together run
   --  every case once and every item of divided work once, and the
   --  transcript of one says SHARD, so it cannot be quoted as the whole.
   type Shard is record
      Index : Positive := 1;
      Count : Positive := 1;
   end record;

   Whole : constant Shard := (Index => 1, Count => 1);

   function Owns (Of_Shard : Shard; Ordinal : Natural) return Boolean is
     (Ordinal mod Of_Shard.Count = Of_Shard.Index - 1);

   --  Whether the running case owns item Ordinal, counted from zero, of
   --  the work it shares out.  True for every item of an ordinary case,
   --  and outside a sharded run, so a case asks it whatever the run is.
   function In_Share (Ordinal : Natural) return Boolean;

   type Summary is record
      Cases  : Natural := 0;
      Passed : Natural := 0;
      Failed : Natural := 0;
      Checks : Natural := 0;
   end record;

   --  What each case cost, from the last Run, in registration-sorted
   --  order.  This is not in the transcript and must not be: the
   --  transcript is parsed, and is the one thing promised to be identical
   --  on every host, which a duration can never be.  The test program
   --  writes these to standard error when LANDIN_TEST_TIMINGS is set, so
   --  a slow run can say where it went instead of being guessed at.
   type Timing is record
      Suite   : Ada.Strings.Unbounded.Unbounded_String;
      Name    : Ada.Strings.Unbounded.Unbounded_String;
      Seconds : Duration := 0.0;
   end record;

   package Timing_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Timing);

   function Last_Timings return Timing_Vectors.Vector;

   --  Told as each suite of a run ends, with the cases it ran, how many
   --  failed and what they cost, so a run of half an hour says where it
   --  is while it is still running rather than only once it ends.  Like
   --  the timings it is never in the transcript; the test program writes
   --  it to standard error.  A nested run passes none.
   type Progress_Report is access procedure
     (Suite   : String;
      Cases   : Natural;
      Failed  : Natural;
      Seconds : Duration);

   --  The line the test program writes for a suite that ended, and the
   --  procedure that writes it to standard error and flushes it, so a
   --  stuck run is told from a slow one by which suite stopped reporting:
   --  "progress: lexer: 42 cases, 0 failed, 3.2s".
   function Progress_Line
     (Suite : String; Cases, Failed : Natural; Seconds : Duration)
      return String;

   procedure Write_Progress
     (Suite : String; Cases, Failed : Natural; Seconds : Duration);

   --  Record_Timings is False by default and the test program is the only
   --  caller that passes True.  The harness suite exercises Run itself, so
   --  a nested run would otherwise clear the timings of the run containing
   --  it: the first measurement lost every suite before `harness` that way
   --  and reported 372 of 741 cases.
   procedure Run
     (In_Registry : Registry;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null);

   --  One shard of the complete run; Whole is the complete run itself.
   procedure Run
     (In_Registry : Registry;
      Of_Shard    : Shard;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null);

   --  One selector of a focused run: a whole suite when Name is empty,
   --  else the one case Suite/Name.  An empty Suite is a `--case=` that
   --  named none, which Selection_Problem refuses.
   type Selector is record
      Suite : Ada.Strings.Unbounded.Unbounded_String;
      Name  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Selector_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Selector);

   --  What is wrong with SELECTED in IN_REGISTRY, or "": a suite no case
   --  is registered under, or a case that is not registered, each answered
   --  with the names nearest it, so a mistyped selection says what the
   --  person meant rather than only that nothing matched.
   function Selection_Problem
     (In_Registry : Registry; Selected : Selector) return String;

   --  The registered names nearest WANTED, as `--suite=` or `--case=`
   --  takes them, at most three, most alike first, comma separated:
   --  suites alone when SUITES, else every SUITE/NAME.
   function Nearest
     (In_Registry : Registry; Wanted : String; Suites : Boolean)
      return String;

   --  Every case any of SELECTED names, once each, in the order a run
   --  sorts them, so one run answers several selectors and each suite's
   --  progress line still says what it cost.  The transcript says
   --  FILTERED with each selector, one to a line.
   procedure Run
     (In_Registry : Registry;
      Selected    : Selector_Vectors.Vector;
      Transcript  : out Ada.Strings.Unbounded.Unbounded_String;
      Result      : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null);

   --  A focused run is developer feedback, not the repository gate.  Empty
   --  filters mean every value at that level; a case filter therefore needs
   --  the suite that owns it.  The transcript says FILTERED so it cannot be
   --  quoted as though the complete inventory ran.
   procedure Run
     (In_Registry : Registry;
      Suite_Filter : String;
      Case_Filter  : String;
      Transcript   : out Ada.Strings.Unbounded.Unbounded_String;
      Result       : out Summary;
      Record_Timings : Boolean := False;
      Progress       : Progress_Report := null)
     with Pre => Case_Filter = "" or else Suite_Filter /= "";

private

   package Unbounded renames Ada.Strings.Unbounded;

   type Context is limited record
      Checks   : Natural := 0;
      Failures : Natural := 0;
      Text     : Unbounded.Unbounded_String;
   end record;

   type Entry_Record is record
      Suite   : Unbounded.Unbounded_String;
      Name    : Unbounded.Unbounded_String;
      Run     : Case_Body;
      Divided : Boolean := False;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Entry_Record);

   type Registry is limited record
      Items : Entry_Vectors.Vector;
   end record;

end Landin.Testing;
