package Plugins::SACDPlayer::TagReader;

# Bounded metadata reader for DSF and DSDIFF (DFF) files.
#
# Design rules:
#   * Audio::Scan is used for DSF and uncompressed DFF when available.
#   * DFF with DST is parsed by DFFParser, never by Audio::Scan (it rejects DST).
#   * Only headers, DIIN and ID3 payloads are read.  The DSD/DST sound payload
#     is always seeked over.
#   * ffprobe is a fallback only, with bounded probesize/analyzeduration.

use strict;
use warnings;

use Encode ();

use Plugins::SACDPlayer::DFFParser;
use Plugins::SACDPlayer::ID3;

my %TAG_ALIAS = (
    TRACKNUMBER  => 'TRACKNUM',
    TRACK        => 'TRACKNUM',
    DISCNUMBER   => 'DISCNUM',
    DISC         => 'DISCNUM',
    YEAR         => 'DATE',
    ALBUM_ARTIST => 'ALBUMARTIST',
    ALBUMARTIST  => 'ALBUMARTIST',
    TOTALTRACKS  => 'TRACKTOTAL',
    TOTALDISCS   => 'DISCTOTAL',
    TRACKTOTAL   => 'TRACKTOTAL',
    DISCTOTAL    => 'DISCTOTAL',
);

my %CACHE;
my $MAX_CACHE = 200;

sub read {
    my ($class, $path, %opts) = @_;
    return undef unless defined $path && length $path && -f $path;

    my $max_tag = $opts{max_tag_size} || 32 * 1024 * 1024;
    my $key = _cache_key($path);
    if ($key && $CACHE{$key}) {
        return { %{ $CACHE{$key} } };
    }

    my $fmt = detect_format($path);
    return undef unless $fmt;

    my $tags;
    if ($fmt eq 'dsf') {
        $tags = $class->_read_dsf($path, $max_tag, %opts);
    }
    else {
        $tags = $class->_read_dff($path, $max_tag, %opts);
    }

    if (!$tags || !$tags->{SECS} || !$tags->{RATE}) {
        my $probe = _ffprobe($path, %opts);
        if ($probe) {
            $tags ||= {};
            for my $k (qw(TITLE ARTIST ALBUM ALBUMARTIST TRACKNUM DISCNUM DATE GENRE)) {
                $tags->{$k} = $probe->{$k}
                    if !defined $tags->{$k} && defined $probe->{$k};
            }
            $tags->{RATE}     ||= $probe->{RATE};
            $tags->{CHANNELS} ||= $probe->{CHANNELS};
            $tags->{SECS}     ||= $probe->{SECS};
            $tags->{SIZE}     ||= $probe->{SIZE};
            $tags->{_sacd}    ||= $probe->{_sacd};
        }
    }

    return undef unless $tags && $tags->{RATE} && $tags->{CHANNELS};

    $tags->{SAMPLESIZE} = 1;
    $tags->{LOSSLESS}   = 1;
    $tags->{AUDIO}      = 1;
    $tags->{CONTENT_TYPE} ||= $fmt;
    $tags->{SIZE} ||= -s $path;
    $tags->{FILESIZE} = -s $path;

    for my $k (keys %$tags) {
        next if $k =~ /^_/;
        next if ref $tags->{$k};
        $tags->{$k} = _clean($tags->{$k});
        delete $tags->{$k} unless defined $tags->{$k};
    }

    if (defined $tags->{TRACKNUM}
        && $tags->{TRACKNUM} =~ m{^\s*(\d+)(?:\s*/\s*(\d+))?}) {
        $tags->{TRACKNUM} = int($1);
        $tags->{TRACKTOTAL} = int($2)
            if defined $2 && !defined $tags->{TRACKTOTAL};
    }
    if (defined $tags->{DISCNUM}
        && $tags->{DISCNUM} =~ m{^\s*(\d+)(?:\s*/\s*(\d+))?}) {
        $tags->{DISCNUM} = int($1);
        $tags->{DISCTOTAL} = int($2)
            if defined $2 && !defined $tags->{DISCTOTAL};
    }

    # LMS's scanner maps SET to DISC/DISCC; keep a compatible value when the
    # file only provided DISCNUM.
    if (defined $tags->{DISCNUM} && !defined $tags->{SET}) {
        $tags->{SET} = $tags->{DISCNUM};
        $tags->{SET} .= '/' . $tags->{DISCTOTAL}
            if defined $tags->{DISCTOTAL} && length $tags->{DISCTOTAL};
    }
    if (defined $tags->{DATE} && $tags->{DATE} =~ /(\d{4})/) {
        $tags->{YEAR} ||= $1;
    }

    if (keys %CACHE > $MAX_CACHE) {
        %CACHE = ();
    }
    $CACHE{$key} = { %$tags } if $key;

    return $tags;
}

sub detect_format {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $head = _read_exact($fh, 16);
    close $fh;
    return undef unless defined $head && length($head) >= 12;

    if (substr($head, 0, 4) eq 'DSD ' && unpack('Q<', substr($head, 4, 8)) == 28) {
        return 'dsf';
    }
    if (substr($head, 0, 4) eq 'FRM8') {
        my $form = substr($head, 12, 4);
        return 'dff' if $form eq 'DSD ' || $form eq 'DST ';
    }
    return undef;
}

sub get_cover_art {
    my ($class, $path, %opts) = @_;
    return undef unless defined $path && -f $path;
    my $fmt = detect_format($path);
    return undef unless $fmt;

    my $max_tag = $opts{max_tag_size} || 32 * 1024 * 1024;
    my @chunks;

    if ($fmt eq 'dsf') {
        my $h = _read_dsf_header($path);
        return undef unless $h && $h->{metadata_offset} > 0;
        @chunks = ({ offset => $h->{metadata_offset}, size => $max_tag });
    }
    else {
        my $p = Plugins::SACDPlayer::DFFParser->parse_file(
            $path, max_tag_size => $max_tag
        );
        return undef unless $p;
        @chunks = @{ $p->{id3_chunks} || [] };
    }

    for my $chunk (@chunks) {
        my $id3 = Plugins::SACDPlayer::ID3->parse_file_at(
            $path, $chunk->{offset}, $chunk->{size},
            max_tag_size => $max_tag,
        );
        next unless $id3 && @{ $id3->{pictures} || [] };
        my $pic = $id3->{pictures}[0];
        return $pic if $pic && $pic->{data};
    }
    return undef;
}

sub _read_dsf {
    my ($class, $path, $max_tag, %opts) = @_;
    my $h = _read_dsf_header($path);
    return undef unless $h;

    my $tags = {
        RATE     => $h->{fs},
        CHANNELS => $h->{channels},
        SECS     => $h->{fs} ? $h->{sample_count} / $h->{fs} : 0,
        SIZE     => $h->{audio_offset} + $h->{audio_size},
        _sacd    => {
            is_dst   => 0,
            fmt      => 'dsf',
            fs       => $h->{fs},
            channels => $h->{channels},
        },
    };

    my $from_scan;
    if (eval { require Audio::Scan; 1 }) {
        my $s = eval { Audio::Scan->scan($path) };
        if ($s && $s->{info}) {
            my $info = $s->{info};
            $tags->{RATE}     = $info->{samplerate} if $info->{samplerate};
            $tags->{CHANNELS} = $info->{channels}   if $info->{channels};
            $tags->{SECS}     = $info->{song_length_ms} / 1000
                if $info->{song_length_ms};
            $tags->{SIZE} = $info->{audio_offset} + $info->{audio_size}
                if $info->{audio_offset} && $info->{audio_size};
            $from_scan = _merge_tags($s->{tags} || {});
        }
    }

    my $from_id3 = _read_id3_at($path, $h->{metadata_offset}, $max_tag);
    my %merged = (%{ $from_scan || {} }, %{ $from_id3 || {} });
    $tags = { %$tags, %merged };
    $tags->{TAGVERSION} ||= $from_id3->{_version} if $from_id3;

    # Remove private keys before returning.
    delete $tags->{_version};
    return $tags;
}

sub _read_dff {
    my ($class, $path, $max_tag, %opts) = @_;
    my $p = Plugins::SACDPlayer::DFFParser->parse_file(
        $path, max_tag_size => $max_tag
    );
    return undef unless $p;

    my $tags = {
        RATE     => $p->{fs},
        CHANNELS => $p->{channels},
        SECS     => $p->{duration},
        SIZE     => $p->{size},
        _sacd    => {
            is_dst   => $p->{is_dst} ? 1 : 0,
            fmt      => 'dff',
            fs       => $p->{fs},
            channels => $p->{channels},
            dst_frames => $p->{dst_frames},
        },
    };

    my %all;
    my $version;
    for my $chunk (@{ $p->{id3_chunks} || [] }) {
        last if $chunk->{offset} < 0;
        my $id3 = Plugins::SACDPlayer::ID3->parse_file_at(
            $path, $chunk->{offset}, $chunk->{size},
            max_tag_size => $max_tag,
        );
        next unless $id3;
        $version ||= $id3->{version};
        while (my ($k, $v) = each %{ $id3->{tags} || {} }) {
            $all{$k} = $v if !defined $all{$k};
        }
    }

    if (!$all{TITLE} && $p->{diti}) {
        $all{TITLE} = $p->{diti};
    }
    if (!$all{ARTIST} && $p->{diar}) {
        $all{ARTIST} = $p->{diar};
    }

    if (!$all{TITLE} && ($opts{tag_fallback} || 'auto') ne 'off') {
        my $probe = _ffprobe($path, %opts);
        if ($probe) {
            for my $k (qw(TITLE ARTIST ALBUM ALBUMARTIST TRACKNUM DISCNUM DATE GENRE)) {
                $all{$k} = $probe->{$k}
                    if !defined $all{$k} && defined $probe->{$k};
            }
            $tags->{RATE}     ||= $probe->{RATE};
            $tags->{CHANNELS} ||= $probe->{CHANNELS};
            $tags->{SECS}     ||= $probe->{SECS};
        }
    }

    $tags = { %$tags, %all };
    $tags->{TAGVERSION} = $version if $version;
    return $tags;
}

sub _read_dsf_header {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $head = _read_exact($fh, 28);
    if (!defined $head || length($head) != 28 || substr($head, 0, 4) ne 'DSD ') {
        close $fh;
        return undef;
    }
    my $chunk_size = unpack('Q<', substr($head, 4, 8));
    my $total_size = unpack('Q<', substr($head, 12, 8));
    my $meta_off   = unpack('Q<', substr($head, 20, 8));
    if ($chunk_size != 28) {
        close $fh;
        return undef;
    }

    seek($fh, 28, 0) or do { close $fh; return undef; };
    my $fmt = _read_exact($fh, 52);
    if (!defined $fmt || length($fmt) != 52
        || substr($fmt, 0, 4) ne 'fmt ' || unpack('Q<', substr($fmt, 4, 8)) != 52)
    {
        close $fh;
        return undef;
    }

    my $version   = unpack('V', substr($fmt, 12, 4));
    my $format_id = unpack('V', substr($fmt, 16, 4));
    my $chan_type = unpack('V', substr($fmt, 20, 4));
    my $channels  = unpack('V', substr($fmt, 24, 4));
    my $fs        = unpack('V', substr($fmt, 28, 4));
    my $bits      = unpack('V', substr($fmt, 32, 4));
    my $samples   = unpack('Q<', substr($fmt, 36, 8));
    my $block     = unpack('V', substr($fmt, 44, 4));

    seek($fh, 80, 0) or do { close $fh; return undef; };
    my $data = _read_exact($fh, 12);
    if (!defined $data || length($data) != 12 || substr($data, 0, 4) ne 'data') {
        close $fh;
        return undef;
    }
    my $data_size = unpack('Q<', substr($data, 4, 8));
    close $fh;

    return undef unless $channels > 0 && $fs > 0 && $data_size >= 12;
    $meta_off = 0 if $meta_off > $total_size;

    return {
        fs              => $fs,
        channels        => $channels,
        bits            => $bits,
        sample_count    => $samples,
        block_size      => $block,
        audio_offset    => 92,
        audio_size      => $data_size - 12,
        metadata_offset => $meta_off,
        total_size      => $total_size,
        version         => $version,
        channel_type    => $chan_type,
    };
}

sub _read_id3_at {
    my ($path, $offset, $max_tag) = @_;
    return undef unless $offset && $offset > 0;
    my $id3 = Plugins::SACDPlayer::ID3->parse_file_at(
        $path, $offset, $max_tag, max_tag_size => $max_tag
    );
    return undef unless $id3;
    my %tags = %{ $id3->{tags} || {} };
    $tags{_version} = $id3->{version};
    return \%tags;
}

sub _merge_tags {
    my ($raw) = @_;
    my %out;
    return \%out unless $raw && ref $raw eq 'HASH';
    while (my ($k, $v) = each %$raw) {
        next unless defined $v;
        $k = uc($k);
        next if $k eq 'APIC' || $k eq 'PIC' || $k eq 'COVERART';
        $k = $TAG_ALIAS{$k} if $TAG_ALIAS{$k};
        if (ref $v eq 'ARRAY') {
            $v = join(', ', map { defined $_ ? $_ : () } @$v);
        }
        next if ref $v;
        $out{$k} = $v;
    }
    return \%out;
}

sub _clean {
    my ($v) = @_;
    return undef unless defined $v;
    return undef if ref $v;
    if (!utf8::is_utf8($v)) {
        my $copy = $v;
        my $decoded;
        eval {
            $decoded = Encode::decode('UTF-8', $copy, Encode::FB_CROAK);
            1;
        };
        if (defined $decoded) {
            $v = $decoded;
        }
        else {
            $v = Encode::decode('ISO-8859-1', $v);
        }
    }
    $v =~ s/\x00+$//g;
    $v =~ s/^\s+//;
    $v =~ s/\s+$//;
    return length($v) ? $v : undef;
}

sub _cache_key {
    my ($path) = @_;
    my @st = stat($path);
    return undef unless @st;
    return join('|', $path, $st[9], $st[7]);
}

sub _ffprobe {
    my ($path, %opts) = @_;
    my $bin = $opts{ffprobe} || 'ffprobe';
    my @cmd = (
        $bin, '-v', 'error',
        '-probesize', '5000000',
        '-analyzeduration', '2000000',
        '-show_entries', 'format=duration:format_tags',
        '-show_entries', 'stream=codec_name,sample_rate,channels,bits_per_raw_sample',
        '-of', 'json',
        $path,
    );

    my ($out, $err) = ('', '');
    my $pid = open(my $fh, '-|', @cmd);
    return undef unless $pid;
    local $SIG{ALRM} = sub { die "ffprobe timeout\n" };
    alarm 5;
    my $ok = eval {
        local $/;
        $out = <$fh>;
        1;
    };
    alarm 0;
    close $fh;
    if (!$ok) {
        kill 'TERM', $pid if $pid;
        return undef;
    }

    my $data = _json_decode($out || '');
    return undef unless $data && ref $data eq 'HASH';

    my %tags;
    my $fmt_tags = $data->{format}{tags} || {};
    my %alias = (
        title => 'TITLE', artist => 'ARTIST', album => 'ALBUM',
        album_artist => 'ALBUMARTIST', albumartist => 'ALBUMARTIST',
        track => 'TRACKNUM', tracknumber => 'TRACKNUM',
        disc => 'DISCNUM', discnumber => 'DISCNUM',
        date => 'DATE', year => 'DATE', genre => 'GENRE',
        composer => 'COMPOSER', performer => 'ARTIST',
        conductor => 'CONDUCTOR', comment => 'COMMENT',
    );
    for my $k (keys %$fmt_tags) {
        my $lk = lc($k);
        my $lk2 = $lk;
        $lk2 =~ s/[\s\-]+/_/g;
        my $to = $alias{$lk2} || $alias{$lk};
        next unless $to;
        my $v = $fmt_tags->{$k};
        next unless defined $v;
        $v = join(', ', @$v) if ref $v eq 'ARRAY';
        $tags{$to} = $v;
    }

    my ($stream) = grep { ($_->{codec_name} || '') =~ /dsd|dst/ }
                   @{ $data->{streams} || [] };
    $stream ||= $data->{streams}[0] if $data->{streams};
    my $rate;
    if ($stream && $stream->{sample_rate}) {
        $rate = int($stream->{sample_rate});
        # FFmpeg reports DSD byte rate; LMS and DSF/DFF headers use bit rate.
        $rate *= 8 if $rate > 0 && $rate < 1000000;
    }
    my $channels = $stream ? $stream->{channels} : undef;
    my $duration = $data->{format}{duration};

    return {
        %tags,
        RATE     => $rate,
        CHANNELS => $channels,
        SECS     => $duration,
        SIZE     => -s $path,
        _sacd    => {
            is_dst => ($stream && ($stream->{codec_name} || '') eq 'dst') ? 1 : 0,
            fmt    => 'ffprobe',
            fs     => $rate,
            channels => $channels,
        },
    };
}

sub _json_decode {
    my ($json) = @_;
    return undef unless length $json;
    for my $mod (qw(JSON::XS JSON::PP JSON)) {
        if (eval "require $mod; 1") {
            my $obj = eval { $mod->new };
            next unless $obj;
            my $res = eval { $obj->decode($json) };
            return $res if $res;
        }
    }
    return undef;
}

sub _read_exact {
    my ($fh, $len) = @_;
    return '' if !$len;
    my $buf = '';
    my $got = 0;
    while ($got < $len) {
        my $n = CORE::read($fh, my $chunk, $len - $got);
        return undef unless defined $n;
        last if $n == 0;
        $buf .= $chunk;
        $got += $n;
    }
    return $got == $len ? $buf : undef;
}

1;
