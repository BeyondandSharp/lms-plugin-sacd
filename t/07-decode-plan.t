use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib 'lib', 't/lib';

BEGIN {
    package main;
    sub SCANNER () { 0 }
    sub DEBUGLOG () { 0 }
}

use Slim::Utils::Prefs;
use Slim::Player::CapabilitiesHelper;
use Plugins::SACDPlayer::Transcoder;
use Plugins::SACDPlayer::Hooks;
use SACDFixtures qw(write_dff id3_v23);

my $dir = tempdir(CLEANUP => 1);

# A fake ffmpeg keeps these tests independent of the host installation: the
# plan builder only needs an executable path (probe output is empty, so the
# resampler falls back to swr).
my $ffmpeg = "$dir/ffmpeg";
open my $ff, '>', $ffmpeg or die "ffmpeg stub: $!\n";
print $ff "#!/bin/sh\nexit 0\n";
close $ff;
chmod 0755, $ffmpeg;

my $prefs = preferences('plugin.sacdplayer');
$prefs->set('ffmpeg', $ffmpeg);

my $client = bless {
    id => 'aa:bb:cc:dd:ee:ff', macaddress => 'aa:bb:cc:dd:ee:ff',
}, 'FakeClient';
sub FakeClient::id { $_[0]{id} }
sub FakeClient::macaddress { $_[0]{macaddress} }
sub FakeClient::maxSupportedSamplerate { 192000 }

my $transcoder = 'Plugins::SACDPlayer::Transcoder';

# --- capability declaration -------------------------------------------------

my $caps = $transcoder->codec_capabilities($client);
is_deeply(
    $caps,
    {
        provider => 'sacd',
        priority => 50,
        decode   => [
            {
                from  => [qw(dff dsf)],
                to    => ['flc'],
                scope => ['local'],
            },
            {
                from  => [qw(dff dsf)],
                to    => ['pcm'],
                scope => ['local'],
                pcm   => { sample_fmt => 's16le', rate => 44100, channels => 2 },
            },
        ],
        encode => [],
    },
    'codec_capabilities declares the SACD decode provider only',
);
is_deeply($caps->{encode}, [], 'no encoder is declared');
is_deeply($transcoder->codec_capabilities, $caps,
    'codec_capabilities works as a class-level probe without a client');

# --- FLAC decode plan -------------------------------------------------------

my $flc = $transcoder->decode_plan($client, 'flc');
ok($flc, 'flc decode plan returned');
is($flc->{format}, 'flc', 'flc plan format');
like($flc->{command}, qr/\Q$ffmpeg\E/, 'flc plan uses the configured ffmpeg');
like($flc->{command}, qr/-i \$FILE\$/, 'flc plan has $FILE$');
like($flc->{command}, qr/\$START\$ \$END\$ \$RESAMPLE\$/, 'flc plan has seek/resample tokens');
like($flc->{command}, qr/-c:a flac -compression_level \d+/, 'flc plan encodes FLAC');
like($flc->{command}, qr/-f flac -$/, 'flc plan streams FLAC on stdout');
is_deeply(
    $flc->{capabilities},
    {
        F => 'noArgs',
        T => 'START=-ss %s',
        U => 'END=-t %w',
        D => 'RESAMPLE=-af aresample=resampler=swr:precision=28:osr=%d',
    },
    'flc plan exposes LMS capabilities',
);

# The FLAC plan must match what setup registers for standalone playback.
$transcoder->setup($client);
is(
    $Slim::Player::TranscodingHelper::commandTable{'dff-flc-*-aa:bb:cc:dd:ee:ff'},
    $flc->{command},
    'setup reuses the same FLAC command as decode_plan',
);

# --- raw PCM decode plan ----------------------------------------------------

my $pcm = $transcoder->decode_plan($client, 'pcm');
ok($pcm, 'pcm decode plan returned');
is($pcm->{format}, 'pcm', 'pcm plan format');
like($pcm->{command}, qr/-i \$FILE\$/, 'pcm plan has $FILE$');
like($pcm->{command}, qr/\$START\$ \$END\$ \$RESAMPLE\$/, 'pcm plan has seek/resample tokens');
like($pcm->{command}, qr/-c:a pcm_s16le -ar 44100 -ac 2 -f s16le -$/,
    'pcm plan defaults to raw s16le/44100/2');
unlike($pcm->{command}, qr/\.(?:wav|flac|m4a|ogg|aif)\b/, 'pcm plan has no container');
is_deeply($pcm->{capabilities}, $flc->{capabilities}, 'pcm plan exposes LMS capabilities');

my $pcm_hi = $transcoder->decode_plan($client, 'pcm', {
    sample_fmt => 's24le', rate => 96000, channels => 6,
});
ok($pcm_hi, 'custom pcm decode plan returned');
like($pcm_hi->{command}, qr/-c:a pcm_s24le -ar 96000 -ac 6 -f s24le -$/,
    'custom pcm plan honours sample_fmt/rate/channels');

my $pcm_case = $transcoder->decode_plan($client, 'PCM', { sample_fmt => 'S16LE' });
ok($pcm_case, 'format/sample_fmt are case-insensitive');
like($pcm_case->{command}, qr/-f s16le -$/, 'uppercase sample_fmt normalised');

ok($transcoder->decode_plan(undef, 'pcm'), 'pcm plan works without a client');

# --- decode-only: no lossy profiles ----------------------------------------

for my $format (qw(aac ogg ops mp3 wav dff)) {
    ok(!defined $transcoder->decode_plan($client, $format),
        "no decode plan for '$format'");
}
ok(!defined $transcoder->decode_plan($client, undef), 'undef format has no plan');

for my $opts (
    { sample_fmt => 'flac' },
    { sample_fmt => 'wav' },
    { rate => 0 },
    { rate => 99999999 },
    { channels => 0 },
    { channels => 9 },
) {
    ok(!defined $transcoder->decode_plan($client, 'pcm', $opts),
        'invalid pcm option rejected: ' . join(',', map { "$_=$opts->{$_}" } sort keys %$opts));
}

# --- missing ffmpeg ---------------------------------------------------------

{
    local $ENV{PATH} = '';
    $prefs->set('ffmpeg', "$dir/no-such-ffmpeg");
    ok(!defined $transcoder->decode_plan($client, 'flc'), 'no flc plan without ffmpeg');
    ok(!defined $transcoder->decode_plan($client, 'pcm'), 'no pcm plan without ffmpeg');
    $prefs->set('ffmpeg', $ffmpeg);
}

# --- chained-profile bitrate protection ------------------------------------

my $fixture = write_dff(
    "$dir/track.dff",
    audio => "\x12\x34" x 1024,
    id3   => id3_v23({ TIT2 => 'Plan', TPE1 => 'Artist' }),
);

# Optional end-to-end check: feed the generated plan to a real FFmpeg.  The
# host is not required to have FFmpeg, so the block is skipped when absent.
my $real_ffmpeg = -x '/usr/bin/ffmpeg' ? '/usr/bin/ffmpeg'
                : -x '/usr/local/bin/ffmpeg' ? '/usr/local/bin/ffmpeg'
                : undef;
SKIP: {
    skip 'no real ffmpeg for decode-plan integration test', 2
        unless $real_ffmpeg && $^O ne 'MSWin32';

    $prefs->set('ffmpeg', $real_ffmpeg);
    my $plan = $transcoder->decode_plan($client, 'pcm', { rate => 44100 });
    my $command = $plan->{command};
    my $out = "$dir/plan.raw";
    $command =~ s/\$FILE\$/"$fixture"/;
    $command =~ s/\$START\$ \$END\$ \$RESAMPLE\$//;
    $command =~ s/ -$/ "$out"/;
    my $rc = system($command);
    $prefs->set('ffmpeg', $ffmpeg);

    is($rc, 0, 'real ffmpeg accepts the raw pcm decode plan');
    ok((-s $out || 0) > 0, 'pcm decode plan produces raw samples');
}

my $track = bless {
    url => 'file://' . $fixture,
    content_type => 'dff',
}, 'FakeTrack';
sub FakeTrack::url { $_[0]{url} }
sub FakeTrack::content_type { $_[0]{content_type} }

my $song = bless { track => $track, client => $client }, 'FakeSong';
sub FakeSong::currentTrack { $_[0]{track} }
sub FakeSong::master { $_[0]{client} }

my $plain = Plugins::SACDPlayer::Hooks::_sacd_sample_and_bitrate($song, {
    profile => 'dff-flc-*-aa:bb:cc:dd:ee:ff',
    streamformat => 'flc',
    command => 'ffmpeg -i x -f flac -',
});
ok($plain, 'plain FLAC transcode reports sample rate/bitrate');
is($plain->{sampleRate}, 176400, 'plain FLAC reports the PCM target rate');
is($plain->{sampleSize}, 24, 'plain FLAC reports 24-bit samples');

for my $marker (qw(post_format codecswitch_chain)) {
    my %transcoder = (
        profile => 'dff-flc-*-aa:bb:cc:dd:ee:ff',
        streamformat => 'flc',
        command => 'ffmpeg -i x -f flac -',
        $marker => 'mp3',
    );
    ok(!defined Plugins::SACDPlayer::Hooks::_sacd_sample_and_bitrate($song, \%transcoder),
        "$marker suppresses the intermediate FLAC bitrate");
}

# The marker must not break the native/DoP paths either.
$prefs->client($client)->set('output_mode', 'native');
ok(!defined Plugins::SACDPlayer::Hooks::_sacd_sample_and_bitrate($song, {
    profile => 'dff-dff-*-aa:bb:cc:dd:ee:ff',
    streamformat => 'dff',
    command => 'sacd_dsd --mode native --input x',
    post_format => 'aac',
}), 'post_format suppresses native DFF bitrate');

done_testing;
