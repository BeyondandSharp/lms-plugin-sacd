package Plugins::SACDPlayer::Route;

use strict;
use warnings;

use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Player::CapabilitiesHelper;
use Plugins::SACDPlayer::Rates ();
use Plugins::SACDPlayer::TagReader;
use Plugins::SACDPlayer::Transcoder;

my $prefs = preferences('plugin.sacdplayer');
my %TAG_CACHE;

sub track_of {
    my ($class, $songOrTrack) = @_;
    return undef unless $songOrTrack;
    if (ref($songOrTrack) && $songOrTrack->isa('Slim::Player::Song')) {
        return $songOrTrack->currentTrack;
    }
    return $songOrTrack;
}

sub client_of {
    my ($class, $songOrTrack) = @_;
    return undef unless $songOrTrack;
    if (ref($songOrTrack) && $songOrTrack->isa('Slim::Player::Song')) {
        return $songOrTrack->master;
    }
    return undef;
}

sub is_sacd {
    my ($class, $track) = @_;
    return 0 unless $track;
    my $url = eval { $track->url } || '';
    my $ct  = eval { $track->content_type } || '';
    return 0 unless $ct eq 'dsf' || $ct eq 'dff'
        || $url =~ /\.(?:dsf|dff)$/i;
    return 1;
}

sub tags_for {
    my ($class, $track) = @_;
    return undef unless $track;
    my $path = $class->path_for_track($track);
    return undef unless $path;
    my @st = stat($path);
    return undef unless @st;
    my $key = join('|', $path, @st[9, 7]);
    return $TAG_CACHE{$key} if $TAG_CACHE{$key};
    my $mb = $prefs->get('max_tag_size_mb') || 32;
    my $tags = Plugins::SACDPlayer::TagReader->read(
        $path,
        max_tag_size => $mb * 1024 * 1024,
        tag_fallback => $prefs->get('tag_fallback') || 'auto',
        ffprobe      => $prefs->get('ffprobe'),
    );
    $TAG_CACHE{$key} = $tags if $tags;
    return $tags;
}

sub path_for_track {
    my ($class, $track) = @_;
    my $url = eval { $track->url } || '';
    return undef unless $url;
    $url =~ s/#.*$//;
    if (eval { require Slim::Music::Info; Slim::Music::Info::isFileURL($url) }) {
        return Slim::Utils::Misc::pathFromFileURL($url);
    }
    $url =~ s/^file:\/\///;
    $url =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $url;
}

sub prefs_for {
    my ($class, $client) = @_;
    return $client ? $prefs->client($client) : $prefs;
}

sub max_samplerate {
    my ($class, $client) = @_;
    return 0 unless $client && $client->can('maxSupportedSamplerate');
    return $client->maxSupportedSamplerate || 0;
}

sub formats {
    my ($class, $client) = @_;
    return () unless $client;
    return eval { Slim::Player::CapabilitiesHelper::supportedFormats($client) };
}

sub has_format {
    my ($class, $client, $fmt) = @_;
    my @formats = $class->formats($client);
    return scalar grep { $_ eq $fmt } @formats;
}

sub _dst_decode_ok {
    my ($class, $track, $hp) = @_;
    return 1 unless $hp;
    return 0 unless $hp->{dst_native};

    my $tags = $class->tags_for($track);
    my $fs = $tags && $tags->{RATE} ? $tags->{RATE} : 0;
    my $max_fs = $hp->{dst_native_max_fs} || 64;
    return 0 if $fs && $fs > $max_fs * 44100;
    return 1;
}

sub _helper_streaming_ok {
    my ($class, $hp) = @_;
    return 0 unless $hp && $hp->{available};
    # 0.2.6 added unbuffered output and fixed DFF CMPR alignment; older
    # helpers return EOF to LMS before the first chunk and cannot play.
    my $v = $hp->{version} || '';
    my @v = split /\./, $v;
    return 0 unless @v >= 3;
    my ($major, $minor, $patch) = map { $_ + 0 } @v[0 .. 2];
    return 1 if $major > 0;
    return 0 if $minor < 2;
    return 0 if $minor == 2 && $patch < 6;
    return 1;
}

sub native_ok {
    my ($class, $track, $client) = @_;
    return 0 unless $track && $client;
    return 0 unless $class->has_format($client, 'dff');
    my $hp = Plugins::SACDPlayer::Transcoder->helper_probe;
    return 0 unless $hp->{available} && $hp->{native};
    return 0 unless $class->_helper_streaming_ok($hp);

    my $tags = $class->tags_for($track);
    if ($tags && $tags->{_sacd} && $tags->{_sacd}{is_dst}) {
        return $class->_dst_decode_ok($track, $hp);
    }
    return 1;
}

sub dop_ok {
    my ($class, $track, $client) = @_;
    return 0 unless $track && $client;
    return 0 unless $class->has_format($client, 'wav');
    my $hp = Plugins::SACDPlayer::Transcoder->helper_probe;
    return 0 unless $hp->{available} && $hp->{dop};
    return 0 unless $class->_helper_streaming_ok($hp);

    my $tags = $class->tags_for($track);
    my $fs = $tags && $tags->{RATE} ? $tags->{RATE} : 0;
    return 0 unless $fs;
    if ($tags->{_sacd} && $tags->{_sacd}{is_dst}) {
        return 0 unless $class->_dst_decode_ok($track, $hp);
    }

    my $cp = $class->prefs_for($client);
    my $max_fs = $cp->get('dop_max_fs') || 128;
    return Plugins::SACDPlayer::Rates::dop_possible(
        $fs, $class->max_samplerate($client), $max_fs
    );
}

sub pcm_ok {
    my $class = shift;
    my $fp = Plugins::SACDPlayer::Transcoder->ffmpeg_probe;
    return $fp->{available} ? 1 : 0;
}

sub preferred_mode {
    my ($class, $track, $client) = @_;
    return 'pcm' unless $class->is_sacd($track);
    my $cp = $class->prefs_for($client);
    my $mode = $cp->get('output_mode') || 'pcm';
    return $mode =~ /^(?:pcm|dop|native)$/ ? $mode : 'pcm';
}

sub select_mode {
    my ($class, $track, $client) = @_;
    return 'pcm' unless $class->is_sacd($track);

    my $mode = $class->preferred_mode($track, $client);
    my @order = $mode eq 'native' ? qw(native dop pcm)
              : $mode eq 'dop'    ? qw(dop native pcm)
              :                     qw(pcm native dop);

    for my $candidate (@order) {
        return 'native' if $candidate eq 'native'
            && $class->native_ok($track, $client);
        return 'dop' if $candidate eq 'dop'
            && $class->dop_ok($track, $client);
        return 'pcm' if $candidate eq 'pcm'
            && $class->pcm_ok;
    }
    return 'pcm';
}

sub pcm_target {
    my ($class, $track, $client) = @_;
    my $tags = $class->tags_for($track);
    my $fs = $tags && $tags->{RATE} ? $tags->{RATE} : 0;
    return 44100 unless $fs;
    my $cp = $class->prefs_for($client);
    return Plugins::SACDPlayer::Rates::pcm_target(
        $fs, $class->max_samplerate($client), $cp->get('pcm_rate')
    );
}

sub output_format {
    my ($class, $mode) = @_;
    return 'dff' if $mode eq 'native';
    return 'wav' if $mode eq 'dop';
    return 'flc';
}

1;
