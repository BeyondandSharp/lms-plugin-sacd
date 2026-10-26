package Plugins::SACDPlayer::Hooks;

# Runtime integration with LMS.  We deliberately avoid editing core files:
# the hooks are installed at plugin post-init and only affect DSF/DFF tracks.

use strict;
use warnings;

use Plugins::SACDPlayer::Route;
use Plugins::SACDPlayer::Transcoder;

my $installed = 0;
my ($orig_convert, $orig_limit, $orig_handle);

sub install {
    return 1 if $installed;

    eval {
        require Slim::Player::TranscodingHelper;
        require Slim::Player::CapabilitiesHelper;
        require Slim::Player::Song;
        1;
    };

    $orig_convert = \&Slim::Player::TranscodingHelper::getConvertCommand2
        if Slim::Player::TranscodingHelper->can('getConvertCommand2');
    $orig_limit = \&Slim::Player::CapabilitiesHelper::samplerateLimit
        if Slim::Player::CapabilitiesHelper->can('samplerateLimit');
    $orig_handle = \&Slim::Player::Song::handleSampleAndBitrate
        if Slim::Player::Song->can('handleSampleAndBitrate');

    no warnings 'redefine';
    *Slim::Player::TranscodingHelper::getConvertCommand2 = \&_getConvertCommand2
        if $orig_convert;
    *Slim::Player::CapabilitiesHelper::samplerateLimit = \&_samplerateLimit
        if $orig_limit;
    *Slim::Player::Song::handleSampleAndBitrate = \&_handleSampleAndBitrate;

    $installed = 1;
    return 1;
}

sub _getConvertCommand2 {
    my @args = @_;
    my ($songOrTrack, $type, $streamModes, $need, $want, $formatOverride) = @args;

    if (!$formatOverride) {
        my $track  = Plugins::SACDPlayer::Route->track_of($songOrTrack);
        my $client = Plugins::SACDPlayer::Route->client_of($songOrTrack);
        if ($track && $client && Plugins::SACDPlayer::Route->is_sacd($track)) {
            my $mode = Plugins::SACDPlayer::Route->select_mode($track, $client);
            my $out  = Plugins::SACDPlayer::Route->output_format($mode);
            if ($mode eq 'native' || $mode eq 'dop') {
                $args[5] = $out;
            }
            elsif (Plugins::SACDPlayer::Route->has_format($client, 'flc')) {
                $args[5] = 'flc';
            }
        }
    }

    return $orig_convert->(@args);
}

sub _samplerateLimit {
    my ($song) = @_;
    my $track  = eval { $song->currentTrack } || $song;
    my $client = eval { $song->master };

    if ($track && $client && Plugins::SACDPlayer::Route->is_sacd($track)) {
        my $mode = Plugins::SACDPlayer::Route->select_mode($track, $client);
        if ($mode eq 'native' || $mode eq 'dop') {
            return undef;
        }
        return Plugins::SACDPlayer::Route->pcm_target($track, $client);
    }

    return $orig_limit->(@_);
}

sub _handleSampleAndBitrate {
    my ($self, $transcoder) = @_;
    my $res = _sacd_sample_and_bitrate($self, $transcoder);
    return $res if $res;
    return $orig_handle->(@_) if $orig_handle;
    return undef;
}

sub _sacd_sample_and_bitrate {
    my ($self, $transcoder) = @_;
    return undef unless $transcoder && ref $transcoder eq 'HASH';

    # A chained profile (SACD decode followed by a CodecSwitch encoder) reports
    # the final target format: the intermediate FLAC/PCM stream is not what the
    # player receives, so its sample rate/bitrate must not be advertised.
    return undef if $transcoder->{post_format} || $transcoder->{codecswitch_chain};

    my $profile = $transcoder->{profile} || '';
    return undef unless $profile =~ /^(?:dsf|dff)-(?:flc|wav|dff)-/;

    my $track = eval { $self->currentTrack } || eval { $self->track } || $self;
    return undef unless $track;
    return undef unless Plugins::SACDPlayer::Route->is_sacd($track);

    my $client = eval { $self->master };
    my $tags   = Plugins::SACDPlayer::Route->tags_for($track);
    return undef unless $tags && $tags->{RATE};
    my $fs     = $tags->{RATE};
    my $ch     = $tags->{CHANNELS} || 2;
    my $format = $transcoder->{streamformat} || '';
    my $cmd    = $transcoder->{command} || '';

    if ($format eq 'dff' && $cmd =~ /--mode\s+native/) {
        return {
            sampleRate => $fs,
            sampleSize => 1,
            bitrate    => $fs ? int($fs * $ch / 8) : undef,
        };
    }

    if ($format eq 'wav' && $cmd =~ /--mode\s+dop/) {
        my $rate = $fs ? int($fs / 16) : 0;
        return {
            sampleRate => $rate,
            sampleSize => 24,
            bitrate    => $rate ? $rate * 24 * $ch : undef,
        };
    }

    if ($format eq 'flc') {
        my $rate = Plugins::SACDPlayer::Route->pcm_target($track, $client);
        return {
            sampleRate => $rate,
            sampleSize => 24,
            bitrate    => $rate * 24 * $ch,
        };
    }

    return undef;
}

1;
