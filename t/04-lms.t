use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib 'lib', 't/lib';
use SACDFixtures qw(write_dff id3_v23);

BEGIN {
    package main;
    sub SCANNER () { 0 }
    sub DEBUGLOG () { 0 }
}

use Slim::Utils::Prefs;
use Slim::Player::CapabilitiesHelper;
use Slim::Player::TranscodingHelper;
use Plugins::SACDPlayer::Transcoder;
use Plugins::SACDPlayer::Route;
use Plugins::SACDPlayer::Hooks;
use Plugins::SACDPlayer::Formats;

my $root = "$Bin/..";
my $helper = "$root/helper/src/sacd_dsd";
my $ffmpeg = -x '/usr/bin/ffmpeg' ? '/usr/bin/ffmpeg'
           : -x '/usr/local/bin/ffmpeg' ? '/usr/local/bin/ffmpeg' : undef;
plan skip_all => 'build helper/src/sacd_dsd first' unless -x $helper;
plan skip_all => 'ffmpeg not found' unless $ffmpeg;

my $p = preferences('plugin.sacdplayer');
$p->set('ffmpeg', $ffmpeg);
$p->set('helper', $helper);

my $client = bless { macaddress => 'aa:bb:cc:dd:ee:ff', id => 'aa:bb:cc:dd:ee:ff' }, 'FakeClient';
sub FakeClient::macaddress { $_[0]{macaddress} }
sub FakeClient::id { $_[0]{id} }
sub FakeClient::maxSupportedSamplerate { 192000 }

my $dir = tempdir(CLEANUP => 1);
my $fixture = write_dff("$dir/test.dff",
    audio => "\x12\x34" x 4096,
    id3   => id3_v23({ TIT2 => 'Test', TPE1 => 'Artist' }),
);
my $track = bless {
    url => 'file://' . $fixture,
    content_type => 'dff',
}, 'FakeTrack';
sub FakeTrack::url { $_[0]{url} }
sub FakeTrack::content_type { $_[0]{content_type} }

my $song = bless { track => $track, client => $client }, 'Slim::Player::Song';
sub Slim::Player::Song::currentTrack { $_[0]{track} }
sub Slim::Player::Song::master { $_[0]{client} }

Plugins::SACDPlayer::Transcoder->setup($client);
ok(exists $Slim::Player::TranscodingHelper::commandTable{"dsf-flc-*-aa:bb:cc:dd:ee:ff"}, 'PCM profile registered');
ok(exists $Slim::Player::TranscodingHelper::commandTable{"dff-dff-*-aa:bb:cc:dd:ee:ff"}, 'native profile registered');
ok(exists $Slim::Player::TranscodingHelper::commandTable{"dff-pcm-*-aa:bb:cc:dd:ee:ff"}, 'DoP profile registered');

Plugins::SACDPlayer::Hooks->install;
$p->client($client)->set('output_mode', 'native');
is(Plugins::SACDPlayer::Route->select_mode($track, $client), 'native', 'native selected');
ok(!defined Slim::Player::CapabilitiesHelper::samplerateLimit($song), 'native bypasses rate limit');

Slim::Player::TranscodingHelper::getConvertCommand2($song, 'dff', [], [], []);
is($Slim::Player::TranscodingHelper::CALLS[-1][5], 'dff', 'native forces dff output');

my $hook = Slim::Player::Song::handleSampleAndBitrate($song, {
    profile => 'dff-dff-*-x', streamformat => 'dff', command => 'x --mode native',
});
is($hook->{sampleRate}, 2822400, 'native sample rate');
is($hook->{sampleSize}, 1, 'native sample size');

$p->client($client)->set('output_mode', 'dop');
is(Plugins::SACDPlayer::Route->select_mode($track, $client), 'dop', 'DoP selected');
$hook = Slim::Player::Song::handleSampleAndBitrate($song, {
    profile => 'dff-pcm-*-x', streamformat => 'pcm', command => 'x --mode dop',
});
is($hook->{sampleRate}, 176400, 'DoP sample rate');
is($hook->{sampleSize}, 24, 'DoP sample size');

$p->client($client)->set('output_mode', 'pcm');
is(Plugins::SACDPlayer::Route->select_mode($track, $client), 'pcm', 'PCM selected');
is(Slim::Player::CapabilitiesHelper::samplerateLimit($song), 176400, 'PCM target rate');

done_testing;
