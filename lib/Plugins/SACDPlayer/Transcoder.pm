package Plugins::SACDPlayer::Transcoder;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.sacdplayer');
my $log   = logger('plugin.sacdplayer');

my %FFMPEG_CACHE;
my %HELPER_CACHE;

sub prefs { $prefs }

sub _which {
    my ($name) = @_;
    return undef unless defined $name && length $name;
    return $name if $name =~ m{^/} && -x $name;

    my $found = Slim::Utils::Misc::findbin($name);
    return $found if $found && -x $found;

    for my $dir (split /:/, $ENV{PATH} || '') {
        next unless length $dir;
        my $path = "$dir/$name";
        return $path if -x $path;
    }
    return undef;
}

sub _bin_token {
    my ($bin) = @_;
    return '[' . $bin . ']' unless defined $bin && $bin =~ m{^/};
    $bin =~ s/"/\\"/g;
    return '"' . $bin . '"';
}

sub ffmpeg_bin {
    my $class = shift;
    my $p = $prefs->get('ffmpeg');
    return $p if $p && -x $p;
    return _which('ffmpeg');
}

sub ffprobe_bin {
    my $class = shift;
    my $p = $prefs->get('ffprobe');
    return $p if $p && -x $p;
    return _which('ffprobe');
}

sub helper_bin {
    my $class = shift;
    my $p = $prefs->get('helper');
    return $p if $p && -x $p;
    return _which('sacd_dsd');
}

sub helper_probe {
    my $class = shift;
    my $bin = $class->helper_bin || return {
        available => 0, native => 0, dop => 0, dst_native => 0,
    };

    my @st = stat($bin);
    my $key = join('|', $bin, @st[9, 7]);
    return $HELPER_CACHE{$key} if $HELPER_CACHE{$key};

    my %caps = (available => 1, native => 0, dop => 0, dst_native => 0);
    my $pid = open(my $fh, '-|', $bin, '--probe');
    if ($pid) {
        my $out = '';
        eval {
            local $SIG{ALRM} = sub { die "probe timeout\n" };
            alarm 3;
            local $/;
            $out = <$fh>;
            alarm 0;
            1;
        };
        alarm 0;
        close $fh;
        if (defined $out) {
            while ($out =~ /^\s*([A-Za-z_]+)\s*=\s*(\S+)\s*$/mg) {
                my ($k, $v) = (lc($1), $2);
                $caps{$k} = $v if exists $caps{$k};
            }
        }
    }

    $HELPER_CACHE{$key} = \%caps;
    return \%caps;
}

sub ffmpeg_probe {
    my $class = shift;
    my $bin = $class->ffmpeg_bin || return { available => 0, soxr => 0 };
    my @st = stat($bin);
    my $key = join('|', $bin, @st[9, 7]);
    return $FFMPEG_CACHE{$key} if $FFMPEG_CACHE{$key};

    my %caps = (available => 1, soxr => 0, flac => 0);
    for my $args (['-filters'], ['-h', 'filter=aresample']) {
        my $pid = open(my $fh, '-|', $bin, '-hide_banner', @$args);
        next unless $pid;
        my $out = '';
        eval {
            local $SIG{ALRM} = sub { die "ffmpeg timeout\n" };
            alarm 5;
            local $/;
            $out = <$fh>;
            alarm 0;
            1;
        };
        alarm 0;
        close $fh;
        $caps{soxr} = 1 if defined $out && $out =~ /\bsoxr\b/;
        last if $caps{soxr};
    }
    $FFMPEG_CACHE{$key} = \%caps;
    return \%caps;
}

sub setup {
    my ($class, $client) = @_;
    return unless $client;

    my $id = $client->id || $client->macaddress || '';
    return unless length $id;

    my $ff     = $class->ffmpeg_bin;
    my $helper = $class->helper_bin;
    my $hp     = $class->helper_probe;
    my $fp     = $class->ffmpeg_probe;

    my $cprefs = $prefs->client($client);
    my $comp   = $cprefs->get('flac_compression');
    $comp = 0 unless defined $comp && $comp =~ /^\d+$/;
    my $rpref = $cprefs->get('resampler') || 'auto';
    my $resampler = $rpref eq 'auto' ? ($fp->{soxr} ? 'soxr' : 'swr') : $rpref;
    $resampler = 'swr' if $resampler eq 'soxr' && !$fp->{soxr};
    $resampler = 'swr' unless $resampler =~ /^(?:soxr|swr)$/;

    my $ffbin = _bin_token($ff || 'ffmpeg');
    my $hbin  = _bin_token($helper || 'sacd_dsd');

    my %add;

    if ($ff) {
        my $filter = '-af aresample=resampler=' . $resampler
            . ':precision=28:osr=%d';
        my $cmd = $ffbin . ' -nostdin -v error -i "$FILE$"'
            . ' -map 0:a:0 -vn $START$ $END$ $RESAMPLE$'
            . ' -c:a flac -compression_level ' . $comp
            . ' -sample_fmt s32 -bits_per_raw_sample 24 -f flac -';

        my $caps = {
            F => 'noArgs',
            T => 'START=-ss %s',
            U => 'END=-t %w',
            D => 'RESAMPLE=' . $filter,
        };

        $add{"dsf-flc-*-$id"} = [ $cmd, $caps ];
        $add{"dff-flc-*-$id"} = [ $cmd, $caps ];
    }

    if ($helper) {
        my $dop_cmd = $hbin . ' --mode dop --input "$FILE$"'
            . ' $START$ $END$';
        my $dop_caps = {
            F => 'noArgs',
            T => 'START=--start %s',
            U => 'END=--end %u',
        };

        my $native_cmd = $hbin . ' --mode native --input "$FILE$"'
            . ' $START$ $END$';
        my $native_caps = {
            F => 'noArgs',
            T => 'START=--start %s',
            U => 'END=--end %u',
        };

        if ($hp->{dop}) {
            $add{"dsf-pcm-*-$id"} = [ $dop_cmd, $dop_caps ];
            $add{"dff-pcm-*-$id"} = [ $dop_cmd, $dop_caps ];
        }
        if ($hp->{native}) {
            $add{"dsf-dff-*-$id"} = [ $native_cmd, $native_caps ];
            $add{"dff-dff-*-$id"} = [ $native_cmd, $native_caps ];
        }
    }

    # Remove stale profiles for this client before adding the current set.
    for my $profile (keys %Slim::Player::TranscodingHelper::commandTable) {
        next unless $profile =~ /^(?:dsf|dff)-(?:flc|pcm|dff)-.*-\Q$id\E$/;
        delete $Slim::Player::TranscodingHelper::commandTable{$profile};
        delete $Slim::Player::TranscodingHelper::capabilities{$profile};
    }

    for my $profile (keys %add) {
        my ($cmd, $caps) = @{ $add{$profile} };
        $Slim::Player::TranscodingHelper::commandTable{$profile} = $cmd;
        $Slim::Player::TranscodingHelper::capabilities{$profile} = $caps;
    }

    $log->debug("SACD profiles for $id: " . join(', ', sort keys %add));
    return 1;
}

sub status {
    my $class = shift;
    my $hp = $class->helper_probe;
    my $fp = $class->ffmpeg_probe;
    return {
        ffmpeg     => $fp->{available} ? 1 : 0,
        soxr       => $fp->{soxr} ? 1 : 0,
        helper     => $hp->{available} ? 1 : 0,
        native     => $hp->{native} ? 1 : 0,
        dop        => $hp->{dop} ? 1 : 0,
        dst_native => $hp->{dst_native} ? 1 : 0,
        ffmpeg_bin => $class->ffmpeg_bin,
        helper_bin => $class->helper_bin,
    };
}

1;
