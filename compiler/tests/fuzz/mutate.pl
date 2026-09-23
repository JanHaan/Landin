#!/usr/bin/env perl
#  One seeded mutation of a Landin source; see README.md.  usage: mutate.pl SEED IN OUT
use strict; use warnings;
my ($seed, $in, $out) = @ARGV; srand($seed);
open my $f, '<', $in or die; local $/; my $s = <$f>; close $f;
my @kw = qw(end begin match if then else elsif while do loop for in break continue with return fail try defer undo sink inout escaping from ptr addr mut type struct variant atom concept is any unchecked zeroed lenof sizeof when complete public import fixed range);
my @punct = ('(', ')', '[', ']', ':', '=', ',', '.', '..', '..<', '->', '!', '|', '+%', '<<', '-', '"', "'", '--', '{-', '-}', "\n", ' ', '0x', '1e999', '99999999999999999999999999');
my $kind = int(rand(7));
my $len = length $s; $len = 1 if $len == 0;
if ($kind == 0) { $s = substr($s, 0, int(rand($len))); }
elsif ($kind == 1) { my @l = split /\n/, $s, -1; splice(@l, int(rand(@l)), 1) if @l; $s = join "\n", @l; }
elsif ($kind == 2) { my @l = split /\n/, $s, -1; my $i = int(rand(@l)); splice(@l, int(rand(@l)), 0, $l[$i]) if @l; $s = join "\n", @l; }
elsif ($kind == 3) { my @w; while ($s =~ /\b[a-z_][a-z0-9_]*\b/g) { push @w, [$-[0], $+[0]-$-[0]]; } if (@w) { my $p = $w[int(rand(@w))]; substr($s, $p->[0], $p->[1]) = $kw[int(rand(@kw))]; } }
elsif ($kind == 4) { my $p = int(rand($len)); substr($s, $p, 0) = $punct[int(rand(@punct))] if $p <= length $s; }
elsif ($kind == 5) { my $p = int(rand($len)); substr($s, $p, 1) = '' if $p < length $s; }
else { my @w; while ($s =~ /\S+/g) { push @w, [$-[0], $+[0]-$-[0]]; } if (@w > 1) { my $a = $w[int(rand(@w))]; my $b = $w[int(rand(@w))]; my ($x,$y) = (substr($s,$a->[0],$a->[1]), substr($s,$b->[0],$b->[1])); if ($a->[0] < $b->[0]) { substr($s,$b->[0],$b->[1]) = $x; substr($s,$a->[0],$a->[1]) = $y; } } }
open my $o, '>', $out or die; print $o $s; close $o;
