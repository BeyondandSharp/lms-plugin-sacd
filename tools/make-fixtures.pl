#!/usr/bin/env perl
use strict;
use warnings;
use lib 't/lib';
use SACDFixtures qw(write_dsf write_dff id3_v23);

my $dir = shift || 't/fixtures';
mkdir $dir unless -d $dir;
my $tags = {
    TIT2 => 'Test Title', TPE1 => 'Test Artist', TALB => 'Test Album',
    TRCK => '3/12', TPOS => '1/2', TDRC => '2024', TCON => 'Jazz',
    COMMENT => 'hello',
};
my $id3 = id3_v23($tags, 'JPEGDATA');
write_dsf("$dir/test.dsf", audio => "\x12\x34" x 4096, id3 => $id3);
write_dff("$dir/test.dff", audio => "\x12\x34" x 4096, id3 => $id3);
write_dff("$dir/test-dst.dff", dst => 1, frames => 75, id3 => $id3);
print "fixtures written to $dir\n";
