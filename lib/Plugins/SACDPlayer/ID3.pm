package Plugins::SACDPlayer::ID3;

# Minimal, bounded ID3v2 reader used for DSDIFF files whose tags Audio::Scan
# refuses to parse (notably DFF with DST sound data).  Only the tag payload is
# read; the caller supplies the chunk offset and size.

use strict;
use warnings;

use Encode ();

my %TEXT_FRAME = (
    'TIT2' => 'TITLE',  'TT2' => 'TITLE',
    'TPE1' => 'ARTIST', 'TP1' => 'ARTIST',
    'TALB' => 'ALBUM',  'TAL' => 'ALBUM',
    'TPE2' => 'ALBUMARTIST', 'TP2' => 'ALBUMARTIST',
    'TRCK' => 'TRACKNUM',    'TRK' => 'TRACKNUM',
    'TPOS' => 'DISCNUM',     'TPA' => 'DISCNUM',
    'TDRC' => 'DATE',        'TYER' => 'DATE',
    'TDAT' => 'DATE',        'TIME' => 'DATE',
    'TCON' => 'GENRE',       'TCO' => 'GENRE',
    'TCOM' => 'COMPOSER',    'TCM' => 'COMPOSER',
    'TPE3' => 'CONDUCTOR',   'TP3' => 'CONDUCTOR',
    'TPUB' => 'LABEL',       'TPB' => 'LABEL',
    'TCOP' => 'COPYRIGHT',   'TCR' => 'COPYRIGHT',
    'TSOA' => 'ALBUMSORT',
    'TSOT' => 'TITLESORT',
    'TSOP' => 'ARTISTSORT',
    'TSO2' => 'ALBUMARTISTSORT',
    'TIT1' => 'GROUPING',
    'TIT3' => 'SUBTITLE',
    'TKEY' => 'INITIALKEY',
    'TBPM' => 'BPM',
    'TMOO' => 'MOOD',
    'TCMP' => 'COMPILATION',
);

sub parse_file_at {
    my ($class, $path, $offset, $size, %opts) = @_;
    return undef unless defined $path && defined $offset;
    open my $fh, '<:raw', $path or return undef;
    my $res = $class->parse_fh_at($fh, $offset, $size, %opts);
    close $fh;
    return $res;
}

sub parse_fh_at {
    my ($class, $fh, $offset, $size, %opts) = @_;
    return undef unless $fh && defined $offset;

    my $max = $opts{max_tag_size} || 32 * 1024 * 1024;
    $max = 32 * 1024 * 1024 if $max < 1024;

    seek($fh, $offset, 0) or return undef;
    my $hdr = _read_exact($fh, 10);
    return undef unless defined $hdr && length($hdr) == 10;
    return undef unless substr($hdr, 0, 3) eq 'ID3';

    my $major = ord(substr($hdr, 3, 1));
    my $rev   = ord(substr($hdr, 4, 1));
    my $flags = ord(substr($hdr, 5, 1));
    return undef unless $major == 2 || $major == 3 || $major == 4;

    my $tag_size = _syncsafe(substr($hdr, 6, 4));
    return undef unless defined $tag_size && $tag_size > 0;
    return undef if $tag_size > $max;

    my $payload = _read_exact($fh, $tag_size);
    return undef unless defined $payload && length($payload) == $tag_size;

    if ($flags & 0x80) {
        $payload = _unsync($payload);
    }

    my $pos = 0;
    if ($flags & 0x40 && length($payload) >= 4) {
        if ($major == 3) {
            my $ext = unpack('N', substr($payload, 0, 4));
            $pos = 4 + $ext if $ext >= 6 && 4 + $ext <= length($payload);
        }
        else {
            my $ext = _syncsafe(substr($payload, 0, 4));
            $pos = 4 + $ext if defined $ext && 4 + $ext <= length($payload);
        }
    }

    my %tags;
    my @pictures;

    while ($pos + 6 <= length($payload)) {
        my ($id, $fsize, $fhdr, $fdata);
        if ($major == 2) {
            $id = substr($payload, $pos, 3);
            last if $id eq "\0\0\0" || $id eq '3DI' || $id =~ /^\0/;
            $fsize = unpack('N', "\0" . substr($payload, $pos + 3, 3));
            $fhdr = 6;
            $fdata = substr($payload, $pos + $fhdr, $fsize);
        }
        else {
            $id = substr($payload, $pos, 4);
            last if $id eq "\0\0\0\0" || $id eq '3DI' || $id =~ /^\0/;
            $fsize = $major == 4
                ? _syncsafe(substr($payload, $pos + 4, 4))
                : unpack('N', substr($payload, $pos + 4, 4));
            $fhdr = 10;
            last unless defined $fsize && $fsize >= 0;
            $fdata = substr($payload, $pos + $fhdr, $fsize);
        }

        last unless defined $fsize;
        last if $fsize < 0;
        last if $pos + $fhdr + $fsize > length($payload);
        $pos += $fhdr + $fsize;

        next unless length($fdata);

        if ($id eq 'APIC' || $id eq 'PIC') {
            my $pic = _parse_picture($id, $fdata);
            push @pictures, $pic if $pic;
            next;
        }

        if ($id eq 'COMM' || $id eq 'COM') {
            my $txt = _parse_comment($fdata);
            $tags{COMMENT} = $txt if defined $txt && length($txt);
            next;
        }

        if ($id eq 'USLT' || $id eq 'ULT') {
            my $txt = _parse_comment($fdata);
            $tags{LYRICS} = $txt if defined $txt && length($txt);
            next;
        }

        if ($id eq 'TXXX' || $id eq 'TXX') {
            my ($desc, $value) = _parse_user_text($fdata);
            if (defined $desc && defined $value) {
                my $key = uc($desc);
                $key =~ s/[^A-Z0-9]+/_/g;
                $key =~ s/^_+|_+$//g;
                if ($key =~ /^REPLAYGAIN_/) {
                    $tags{$key} = $value;
                }
                elsif ($key =~ /^MUSICBRAINZ_/) {
                    $tags{$key} = $value;
                }
                elsif ($key eq 'ALBUMARTIST' || $key eq 'ALBUM_ARTIST') {
                    $tags{ALBUMARTIST} = $value;
                }
                elsif ($key eq 'TRACKTOTAL' || $key eq 'TOTALTRACKS') {
                    $tags{TRACKTOTAL} = $value;
                }
                elsif ($key eq 'DISCTOTAL' || $key eq 'TOTALDISCS') {
                    $tags{DISCTOTAL} = $value;
                }
            }
            next;
        }

        if (my $key = $TEXT_FRAME{$id}) {
            my $text = _parse_text($fdata);
            next unless defined $text;
            $tags{$key} = $text;
        }
    }

    if (defined $tags{TRACKNUM} && $tags{TRACKNUM} =~ m{^\s*(\d+)\s*/\s*(\d+)}) {
        $tags{TRACKNUM}  = int($1);
        $tags{TRACKTOTAL} = int($2) unless defined $tags{TRACKTOTAL};
    }
    if (defined $tags{DISCNUM} && $tags{DISCNUM} =~ m{^\s*(\d+)\s*/\s*(\d+)}) {
        $tags{DISCNUM}  = int($1);
        $tags{DISCTOTAL} = int($2) unless defined $tags{DISCTOTAL};
    }
    if (defined $tags{DATE} && $tags{DATE} =~ /(\d{4})/) {
        $tags{DATE} = $1;
    }

    return {
        tags     => \%tags,
        pictures => \@pictures,
        version  => "$major.$rev",
    };
}

sub _parse_text {
    my ($data) = @_;
    return undef unless defined $data && length($data);
    my $enc = ord(substr($data, 0, 1));
    my $bytes = substr($data, 1);
    return _decode($bytes, $enc);
}

sub _parse_comment {
    my ($data) = @_;
    return undef unless defined $data && length($data) >= 4;
    my $enc = ord(substr($data, 0, 1));
    my $rest = substr($data, 4); # language + short description
    my $zero = $enc == 1 || $enc == 2 ? "\0\0" : "\0";
    my $idx = index($rest, $zero);
    $rest = substr($rest, $idx + length($zero)) if $idx >= 0;
    return _decode($rest, $enc);
}

sub _parse_user_text {
    my ($data) = @_;
    return unless defined $data && length($data) >= 2;
    my $enc = ord(substr($data, 0, 1));
    my $rest = substr($data, 1);
    my $zero = $enc == 1 || $enc == 2 ? "\0\0" : "\0";
    my $idx = index($rest, $zero);
    return unless $idx >= 0;
    my $desc = _decode(substr($rest, 0, $idx), $enc);
    my $value = _decode(substr($rest, $idx + length($zero)), $enc);
    return ($desc, $value);
}

sub _parse_picture {
    my ($id, $data) = @_;
    return undef unless defined $data && length($data) > 4;
    my $enc = ord(substr($data, 0, 1));
    my $rest = substr($data, 1);
    my ($mime, $type, $desc, $bytes);

    if ($id eq 'PIC') {
        return undef unless length($rest) >= 4;
        my $fmt = substr($rest, 0, 3);
        $mime = $fmt eq 'JPG' ? 'image/jpeg' : $fmt eq 'PNG' ? 'image/png' : "image/$fmt";
        $type = ord(substr($rest, 3, 1));
        $rest = substr($rest, 4);
    }
    else {
        my $idx = index($rest, "\0");
        return undef if $idx < 0;
        $mime = substr($rest, 0, $idx);
        $mime = 'image/jpeg' unless length $mime;
        $rest = substr($rest, $idx + 1);
        return undef unless length($rest) >= 1;
        $type = ord(substr($rest, 0, 1));
        $rest = substr($rest, 1);
    }

    my $zero = $enc == 1 || $enc == 2 ? "\0\0" : "\0";
    my $idx = index($rest, $zero);
    if ($idx >= 0) {
        $desc = _decode(substr($rest, 0, $idx), $enc);
        $rest = substr($rest, $idx + length($zero));
    }
    $bytes = $rest;
    return undef unless defined $bytes && length($bytes);
    return {
        mime        => $mime,
        type        => $type,
        description => $desc,
        data        => $bytes,
    };
}

sub _decode {
    my ($bytes, $enc) = @_;
    return undef unless defined $bytes;
    $bytes =~ s/\x00+$// if $enc != 1 && $enc != 2;

    my $out;
    if ($enc == 0) {
        $out = Encode::decode('ISO-8859-1', $bytes);
    }
    elsif ($enc == 1) {
        $out = eval { Encode::decode('UTF-16', $bytes) };
        $out = eval { Encode::decode('UTF-16LE', $bytes) } unless defined $out;
    }
    elsif ($enc == 2) {
        $out = eval { Encode::decode('UTF-16BE', $bytes) };
    }
    else {
        $out = eval { Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT) };
    }
    return $out;
}

sub _syncsafe {
    my ($bytes) = @_;
    return undef unless defined $bytes && length($bytes) == 4;
    my @b = unpack('C4', $bytes);
    return undef if grep { $_ & 0x80 } @b;
    return ($b[0] << 21) | ($b[1] << 14) | ($b[2] << 7) | $b[3];
}

sub _unsync {
    my ($data) = @_;
    $data =~ s/\xFF\x00/\xFF/g;
    return $data;
}

sub _read_exact {
    my ($fh, $len) = @_;
    return '' if !$len;
    my $buf = '';
    my $got = 0;
    while ($got < $len) {
        my $n = read($fh, my $chunk, $len - $got);
        return undef unless defined $n;
        last if $n == 0;
        $buf .= $chunk;
        $got += $n;
    }
    return $got == $len ? $buf : undef;
}

1;
