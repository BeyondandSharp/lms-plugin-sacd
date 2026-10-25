use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib', 't/lib';
use SACDFixtures qw(id3_v24);
use Plugins::SACDPlayer::ID3;

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/test.id3";
open my $fh, '>:raw', $path or die $!;
print $fh id3_v24({ TIT2 => 'V24 Title', TPE1 => 'V24 Artist' });
close $fh;

my $id3 = Plugins::SACDPlayer::ID3->parse_file_at($path, 0, 1000);
is($id3->{version}, '4.0', 'ID3v2.4 recognized');
is($id3->{tags}{TITLE}, 'V24 Title', 'ID3v2.4 title');
is($id3->{tags}{ARTIST}, 'V24 Artist', 'ID3v2.4 artist');

done_testing;
