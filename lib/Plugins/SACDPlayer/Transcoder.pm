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

# Raw PCM formats this plugin can decode DSD/DST to.  Containers and lossy
# codecs are deliberately not listed: final AAC/Ogg/Opus encoding belongs to
# CodecSwitch/FFmpeg, this plugin is a decode-only provider.
my %PCM_SAMPLE_FMT = map { $_ => 1 } qw(s16le s24le);
my %PCM_CODEC = (s16le => 'pcm_s16le', s24le => 'pcm_s24le');
my %PCM_DEFAULT = (sample_fmt => 's16le', rate => 44100, channels => 2);

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
        dst_native_max_fs => 0, version => '',
    };

    my @st = stat($bin);
    my $key = join('|', $bin, @st[9, 7]);
    return $HELPER_CACHE{$key} if $HELPER_CACHE{$key};

    my %caps = (available => 1, native => 0, dop => 0, dst_native => 0,
                dst_native_max_fs => 0, version => '');
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

sub _client_prefs {
    my ($class, $client) = @_;
    return $client ? $prefs->client($client) : $prefs;
}

sub _flac_compression {
    my ($class, $client) = @_;
    my $comp = $class->_client_prefs($client)->get('flac_compression');
    return 0 unless defined $comp && $comp =~ /^\d+$/;
    return $comp;
}

sub _resampler_name {
    my ($class, $client) = @_;
    my $fp = $class->ffmpeg_probe;
    my $rpref = $class->_client_prefs($client)->get('resampler') || 'auto';
    my $resampler = $rpref eq 'auto' ? ($fp->{soxr} ? 'soxr' : 'swr') : $rpref;
    $resampler = 'swr' if $resampler eq 'soxr' && !$fp->{soxr};
    $resampler = 'swr' unless $resampler =~ /^(?:soxr|swr)$/;
    return $resampler;
}

# LMS capability hashref shared by the FLAC and raw PCM decode commands:
# F=file input, T=start, U=end, D=downsample (the $RESAMPLE$ token).
sub _base_capabilities {
    my ($class, $resampler) = @_;
    return {
        F => 'noArgs',
        T => 'START=-ss %s',
        U => 'END=-t %w',
        D => 'RESAMPLE=-af aresample=resampler=' . $resampler
            . ':precision=28:osr=%d',
    };
}

sub _flac_plan {
    my ($class, $client) = @_;
    my $ff = $class->ffmpeg_bin || return undef;
    my $comp      = $class->_flac_compression($client);
    my $resampler = $class->_resampler_name($client);

    my $command = _bin_token($ff) . ' -nostdin -v error -i $FILE$'
        . ' -map 0:a:0 -vn $START$ $END$ $RESAMPLE$'
        . ' -c:a flac -compression_level ' . $comp
        . ' -sample_fmt s32 -bits_per_raw_sample 24 -f flac -';

    return {
        command      => $command,
        capabilities => $class->_base_capabilities($resampler),
    };
}

sub _pcm_opts {
    my ($class, $opts) = @_;
    my %out = %PCM_DEFAULT;
    if (ref $opts eq 'HASH') {
        for my $key (keys %PCM_DEFAULT) {
            my $value = $opts->{$key};
            next unless defined $value && !ref $value && length "$value";
            $out{$key} = lc "$value" if $key eq 'sample_fmt';
            $out{$key} = $value      if $key ne 'sample_fmt';
        }
    }

    return undef unless $PCM_SAMPLE_FMT{ $out{sample_fmt} };
    return undef unless "$out{rate}" =~ /^\d+$/
        && $out{rate} >= 8000 && $out{rate} <= 1536000;
    return undef unless "$out{channels}" =~ /^\d+$/
        && $out{channels} >= 1 && $out{channels} <= 8;

    $out{rate}     = int $out{rate};
    $out{channels} = int $out{channels};
    return \%out;
}

sub _pcm_plan {
    my ($class, $client, $opts) = @_;
    my $ff = $class->ffmpeg_bin || return undef;
    my $pcm = $class->_pcm_opts($opts) || return undef;
    my $resampler = $class->_resampler_name($client);
    my $fmt = $pcm->{sample_fmt};

    # Raw little-endian PCM on stdout, no container: the consumer (LMS or a
    # CodecSwitch encoder) receives exactly the declared format.
    my $command = _bin_token($ff) . ' -nostdin -v error -i $FILE$'
        . ' -map 0:a:0 -vn $START$ $END$ $RESAMPLE$'
        . ' -c:a ' . $PCM_CODEC{$fmt}
        . ' -ar ' . $pcm->{rate}
        . ' -ac ' . $pcm->{channels}
        . ' -f ' . $fmt . ' -';

    return {
        command      => $command,
        capabilities => $class->_base_capabilities($resampler),
        pcm          => $pcm,
    };
}

sub setup {
    my ($class, $client) = @_;
    return unless $client;

    my $id = $client->id || $client->macaddress || '';
    return unless length $id;

    my $helper = $class->helper_bin;
    my $hp     = $class->helper_probe;

    my $hbin  = _bin_token($helper || 'sacd_dsd');

    my %add;

    my $flac = $class->_flac_plan($client);
    if ($flac) {
        $add{"dsf-flc-*-$id"} = [ $flac->{command}, $flac->{capabilities} ];
        $add{"dff-flc-*-$id"} = [ $flac->{command}, $flac->{capabilities} ];
    }

    if ($helper) {
        my $dop_cmd = $hbin . ' --mode dop --wav --input $FILE$'
            . ' $START$ $END$';
        my $dop_caps = {
            F => 'noArgs',
            T => 'START=--start %s',
            U => 'END=--end %u',
        };

        my $native_cmd = $hbin . ' --mode native --input $FILE$'
            . ' $START$ $END$';
        my $native_caps = {
            F => 'noArgs',
            T => 'START=--start %s',
            U => 'END=--end %u',
        };

        if ($hp->{dop}) {
            $add{"dsf-wav-*-$id"} = [ $dop_cmd, $dop_caps ];
            $add{"dff-wav-*-$id"} = [ $dop_cmd, $dop_caps ];
        }
        if ($hp->{native}) {
            $add{"dsf-dff-*-$id"} = [ $native_cmd, $native_caps ];
            $add{"dff-dff-*-$id"} = [ $native_cmd, $native_caps ];
        }
    }

    # Remove stale profiles for this client before adding the current set.
    for my $profile (keys %Slim::Player::TranscodingHelper::commandTable) {
        next unless $profile =~ /^(?:dsf|dff)-(?:flc|wav|dff)-.*-\Q$id\E$/;
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

# Optional capability declaration for an orchestration layer (CodecSwitch).
# This plugin only decodes DSD/DST: it never declares an encoder.
sub codec_capabilities {
    my ($class, $client) = @_;
    return {
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
    };
}

# decode_plan($client, $format, $opts) -> { command, capabilities, format }
#
# $format is 'flc' (lossless FLAC) or 'pcm' (raw little-endian PCM).  The
# command is an LMS profile-style command using $FILE$/$START$/$END$/$RESAMPLE$
# and capabilities is an LMS capability hashref, so an orchestration layer can
# append an encoder and register the composed profile.  Any other format
# (including aac/ogg/ops) returns undef: lossy targets are owned by
# CodecSwitch/FFmpeg.
sub decode_plan {
    my ($class, $client, $format, $opts) = @_;
    return undef unless defined $format && !ref $format;

    $format = lc $format;
    $format =~ s/^\s+|\s+$//g;
    $format = 'flc' if $format eq 'flac';

    my $plan;
    if ($format eq 'flc') {
        $plan = $class->_flac_plan($client);
    }
    elsif ($format eq 'pcm') {
        $plan = $class->_pcm_plan($client, $opts);
    }
    else {
        return undef;
    }
    return undef unless $plan;

    return {
        command      => $plan->{command},
        capabilities => $plan->{capabilities},
        format       => $format,
    };
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
        dst_native_max_fs => $hp->{dst_native_max_fs} || 0,
        helper_version => $hp->{version} || '',
        ffmpeg_bin => $class->ffmpeg_bin,
        helper_bin => $class->helper_bin,
    };
}

1;
