package Plugins::SACDPlayer::Rates;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
    pcm_target dop_rate dop_possible dsd_label is_dsd_rate
    dst_frame_bytes pcm_multiple
);

my @PCM_RATES = (44100, 88200, 176400, 352800);

sub is_dsd_rate {
    my ($fs) = @_;
    return 0 unless $fs && $fs =~ /^\d+$/;
    return $fs >= 2822400 && $fs % 44100 == 0;
}

sub dsd_label {
    my ($fs) = @_;
    return '' unless is_dsd_rate($fs);
    my $mult = int($fs / 44100);
    return "DSD$mult";
}

# DSD bit rate -> PCM sample rate for FLAC output.  DSD64 is 352.8 kHz;
# higher rates are reduced to at most 352.8 kHz, and to a 44.1 kHz family
# rate that the player can actually accept.
sub pcm_target {
    my ($fs, $client_max, $pref) = @_;
    $fs = 0 unless defined $fs;
    my $native = int($fs / 8);
    my $want = ($pref && $pref ne 'auto') ? int($pref) : $native;

    $want = 352800 if !$want || $want > 352800;
    $want = 44100  if $want < 44100;

    if ($client_max && $client_max > 0 && $want > $client_max) {
        $want = $client_max;
    }

    my $target = 44100;
    for my $r (@PCM_RATES) {
        $target = $r if $r <= $want;
    }
    return $target;
}

sub pcm_multiple {
    my ($rate) = @_;
    return int($rate / 44100) if $rate && $rate % 44100 == 0;
    return 0;
}

sub dop_rate {
    my ($fs) = @_;
    return 0 unless $fs;
    return int($fs / 16);
}

sub dop_possible {
    my ($fs, $client_max, $max_fs) = @_;
    return 0 unless is_dsd_rate($fs);
    my $rate = dop_rate($fs);
    return 0 unless $rate >= 176400;
    return 0 if $rate > 1411200;

    if ($max_fs) {
        my $cap = int($max_fs) * 44100;
        return 0 if $fs > $cap;
    }
    if ($client_max && $client_max > 0 && $rate > $client_max) {
        return 0;
    }
    return 1;
}

sub dst_frame_bytes {
    my ($fs) = @_;
    return 0 unless is_dsd_rate($fs);
    return int($fs / 600);
}

1;
