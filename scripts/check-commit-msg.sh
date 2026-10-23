#!/usr/bin/env bash
# Checks a commit message file against the repo's message rules:
#   - no em dash (U+2014)
#   - no emoji
#   - no hidden or invisible Unicode (zero-width, bidi controls, odd spaces, BOM, control chars)
#   - no Co-Authored-By trailer and no "Generated with" attribution line
# Lines starting with "#" and everything below git's scissors line are ignored, as git drops them.
# Used by .githooks/commit-msg and by the commit-messages workflow.

set -euo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 <commit-message-file>" >&2
  exit 2
fi

exec perl -CSD -Mutf8 -e '
  use strict;
  use warnings;
  use Encode qw(decode FB_CROAK);

  my $file = shift;
  open(my $fh, "<:raw", $file) or die "cannot read $file: $!\n";
  my $errors = 0;
  my $n = 0;

  sub report {
    my ($line, $what) = @_;
    print STDERR "  line $line: $what\n";
    $errors++;
  }

  while (my $raw = <$fh>) {
    $n++;
    last if $raw =~ /^# -+ >8 -+/;
    next if $raw =~ /^#/;

    my $line = eval { decode("UTF-8", $raw, FB_CROAK) };
    if (!defined $line) { report($n, "not valid UTF-8"); next; }
    $line =~ s/\r?\n\z//;

    report($n, "em dash (U+2014), use a plain hyphen or rephrase") if $line =~ /\x{2014}/;

    while ($line =~ /([\x{1F000}-\x{1FAFF}\x{1F1E6}-\x{1F1FF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{2300}-\x{23FF}\x{3030}\x{303D}\x{3297}\x{3299}\x{20E3}\x{FE00}-\x{FE0F}])/g) {
      report($n, sprintf("emoji or emoji modifier U+%04X", ord $1));
    }

    while ($line =~ /([\x{00}-\x{08}\x{0B}-\x{1F}\x{7F}-\x{9F}\x{00A0}\x{00AD}\x{034F}\x{061C}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180E}\x{2000}-\x{200F}\x{2028}-\x{202F}\x{205F}-\x{206F}\x{3000}\x{3164}\x{FEFF}\x{FFA0}\x{FFF9}-\x{FFFB}\x{E0000}-\x{E007F}])/g) {
      report($n, sprintf("hidden or invisible character U+%04X", ord $1));
    }

    report($n, "Co-Authored-By trailer is not allowed") if $line =~ /^\s*co-authored-by\s*:/i;
    report($n, "\"Generated with\" attribution line is not allowed") if $line =~ /generated (with|by) \[?claude/i;
  }

  if ($errors) {
    print STDERR "Commit message rejected ($errors problem" . ($errors == 1 ? "" : "s") . ").\n";
    exit 1;
  }
' "$1"
