use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib', 't/lib';
use SACDFixtures qw(write_dsf write_dff id3_v23);
use Plugins::SACDPlayer::TagReader;
use Plugins::SACDPlayer::Formats::DSF;

my $dir = tempdir(CLEANUP => 1);
my $tags = {
    TIT2 => 'Test Title', TPE1 => 'Test Artist', TALB => 'Test Album',
    TRCK => '3/12', TPOS => '1/2', TDRC => '2024', TCON => 'Jazz',
    COMMENT => 'hello',
};

my $dsf = write_dsf("$dir/test.dsf",
    audio => "\x12\x34" x 4096,
    id3   => id3_v23($tags, 'JPEGDATA'),
);
my $t = Plugins::SACDPlayer::TagReader->read($dsf);
is($t->{TITLE}, 'Test Title', 'DSF title');
is($t->{ARTIST}, 'Test Artist', 'DSF artist');
is($t->{ALBUM}, 'Test Album', 'DSF album');
is($t->{TRACKNUM}, 3, 'DSF track number');
is($t->{RATE}, 2822400, 'DSF bit rate');
is($t->{CHANNELS}, 2, 'DSF channels');
is($t->{SAMPLESIZE}, 1, 'DSF sample size');
ok($t->{SECS} > 0, 'DSF duration');
is($t->{_sacd}{is_dst}, 0, 'DSF not DST');
is($t->{SIZE}, 92 + 8192, 'DSF size follows core DSD.pm');

my $public = Plugins::SACDPlayer::Formats::DSF->getTag($dsf);
ok($public && !exists $public->{_sacd}, 'LMS-facing tags omit private metadata');

my $pic = Plugins::SACDPlayer::TagReader->get_cover_art($dsf);
is($pic->{mime}, 'image/jpeg', 'DSF cover mime');
is($pic->{data}, 'JPEGDATA', 'DSF cover data');

my $dff = write_dff("$dir/test.dff",
    audio => "\x12\x34" x 4096,
    id3   => id3_v23($tags, 'JPEGDATA'),
);
$t = Plugins::SACDPlayer::TagReader->read($dff);
is($t->{TITLE}, 'Test Title', 'DFF title');
is($t->{RATE}, 2822400, 'DFF bit rate');
is($t->{CHANNELS}, 2, 'DFF channels');
is($t->{_sacd}{is_dst}, 0, 'DFF not DST');
ok($t->{SECS} > 0, 'DFF duration');

my $dst = write_dff("$dir/test-dst.dff",
    dst => 1, frames => 75,
    id3 => id3_v23($tags, 'JPEGDATA'),
);
$t = Plugins::SACDPlayer::TagReader->read($dst);
is($t->{_sacd}{is_dst}, 1, 'DFF DST recognized');
is($t->{TITLE}, 'Test Title', 'DST title from ID3');
is($t->{SECS}, 1, 'DST duration from FRTE');
is($t->{SIZE}, -s $dst, 'DST size is file size');
$pic = Plugins::SACDPlayer::TagReader->get_cover_art($dst);
is($pic->{data}, 'JPEGDATA', 'DST cover from ID3');

done_testing;
