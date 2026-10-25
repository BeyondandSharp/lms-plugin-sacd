package Plugins::SACDPlayer::PlayerSettings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Player::CapabilitiesHelper;
use Plugins::SACDPlayer::Plugin;
use Plugins::SACDPlayer::Transcoder;

my $prefs = preferences('plugin.sacdplayer');

sub getDisplayName {
    return 'PLUGIN_SACDPLAYER';
}

sub needsClient {
    return 1;
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SACDPLAYER');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/SACDPlayer/settings/player.html');
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    my $cp = $prefs->client($client);

    if ($params->{saveSettings}) {
        my $mode = $params->{pref_output_mode} || 'pcm';
        $mode = 'pcm' unless $mode =~ /^(?:pcm|dop|native)$/;
        $cp->set('output_mode', $mode);

        my $rate = $params->{pref_pcm_rate} || 'auto';
        $rate = 'auto' unless $rate =~ /^(?:auto|44100|88200|176400|352800)$/;
        $cp->set('pcm_rate', $rate);

        my $dop = $params->{pref_dop_max_fs} || 128;
        $dop = 128 unless $dop =~ /^(?:64|128|256)$/;
        $cp->set('dop_max_fs', $dop);

        my $comp = $params->{pref_flac_compression} || 0;
        $comp = 0 unless $comp =~ /^(?:0|5|8)$/;
        $cp->set('flac_compression', $comp);

        my $res = $params->{pref_resampler} || 'auto';
        $res = 'auto' unless $res =~ /^(?:auto|soxr|swr)$/;
        $cp->set('resampler', $res);

        Plugins::SACDPlayer::Plugin->setupTranscoder($client);
    }

    my @formats = Slim::Player::CapabilitiesHelper::supportedFormats($client);
    my %formats = map { $_ => 1 } @formats;
    my $hp = Plugins::SACDPlayer::Transcoder->helper_probe;
    my $fp = Plugins::SACDPlayer::Transcoder->ffmpeg_probe;
    my $max = $client->can('maxSupportedSamplerate')
        ? ($client->maxSupportedSamplerate || 0) : 0;

    $params->{prefs} = {
        output_mode      => $cp->get('output_mode') || 'pcm',
        pcm_rate         => $cp->get('pcm_rate') || 'auto',
        dop_max_fs       => $cp->get('dop_max_fs') || 128,
        flac_compression => defined $cp->get('flac_compression')
            ? $cp->get('flac_compression') : 0,
        resampler        => $cp->get('resampler') || 'auto',
    };
    $params->{capabilities} = {
        pcm      => $fp->{available} ? 1 : 0,
        native   => ($formats{dff} && $hp->{native}) ? 1 : 0,
        dop      => ($formats{pcm} && $hp->{dop}) ? 1 : 0,
        dst      => $hp->{dst_native} ? 1 : 0,
        max_rate => $max,
        formats  => join(',', @formats),
    };
    $params->{status} = Plugins::SACDPlayer::Transcoder->status;

    return $class->SUPER::handler($client, $params);
}

1;
