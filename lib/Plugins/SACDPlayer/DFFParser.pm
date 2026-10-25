package Plugins::SACDPlayer::DFFParser;

# Header-only DSDIFF (DFF) parser.
#
# This module deliberately never reads the DSD/DST sound payload.  It seeks
# over the sound chunks and only reads chunk headers plus the small metadata
# chunks (PROP/FS, CHNL, CMPR, FRTE, DIIN/DIAR, DIIN/DITI).  ID3 chunks are
# returned as offsets so the caller can apply its own size limit.

use strict;
use warnings;

use Encode ();

sub parse_file {
    my ($class, $path, %opts) = @_;
    return undef unless defined $path && -f $path;

    open my $fh, '<:raw', $path or return undef;
    my $res = $class->parse_fh($fh, %opts);
    close $fh;
    return $res;
}

sub parse_fh {
    my ($class, $fh, %opts) = @_;
    return undef unless $fh;

    my $file_size = _file_size($fh);
    return undef unless defined $file_size && $file_size >= 16;

    seek($fh, 0, 0) or return undef;
    my $head = _read_exact($fh, 16);
    return undef unless defined $head && length($head) == 16;

    my ($id, $size, $form) = unpack('a4 Q> a4', $head);
    return undef unless $id eq 'FRM8';
    return undef unless $form eq 'DSD ' || $form eq 'DST ';

    my $total_end = 12 + $size;
    $total_end = $file_size if $total_end > $file_size;

    my $self = bless {
        file_size    => $file_size,
        form         => $form,
        fs           => 0,
        channels     => 0,
        channel_ids  => [],
        compression  => '',
        audio_offset => 0,
        audio_size   => 0,
        dst_frames   => 0,
        dst_rate     => 75,
        is_dst       => ($form eq 'DST '),
        id3_chunks   => [],
        diar         => undef,
        diti         => undef,
        max_tag_size => $opts{max_tag_size} || 32 * 1024 * 1024,
    }, $class;

    my $offset = 16;
    while ($offset + 12 <= $total_end) {
        seek($fh, $offset, 0) or last;
        my $hdr = _read_exact($fh, 12);
        last unless defined $hdr && length($hdr) == 12;

        my ($cid, $csize) = unpack('a4 Q>', $hdr);
        my $data_off = $offset + 12;
        my $data_end = $data_off + $csize;

        # A corrupt size must not make us loop forever or read random data.
        last if $data_end > $total_end + 1;
        last if $csize > $file_size;

        if ($cid eq 'PROP') {
            $self->_parse_prop($fh, $data_off, $csize, $total_end);
        }
        elsif ($cid eq 'DSD ') {
            $self->{audio_offset} = $data_off;
            $self->{audio_size}   = $csize;
        }
        elsif ($cid eq 'DST ') {
            $self->{is_dst} = 1;
            $self->_parse_dst($fh, $data_off, $csize, $total_end);
        }
        elsif ($cid eq 'DIIN') {
            $self->_parse_diin($fh, $data_off, $csize, $total_end);
        }
        elsif ($cid eq 'ID3 ' || $cid eq 'id3 ') {
            push @{ $self->{id3_chunks} }, {
                offset => $data_off,
                size   => $csize,
            };
        }
        elsif ($cid eq 'DSTI') {
            # Optional index; not needed for metadata, but it confirms DST.
            $self->{is_dst} = 1;
        }

        $offset = $data_end + ($csize % 2 ? 1 : 0);
    }

    return undef unless $self->{fs} > 0 && $self->{channels} > 0;
    return undef unless $self->{form} eq 'DSD ' || $self->{form} eq 'DST ';

    if ($self->{is_dst}) {
        return undef unless $self->{dst_frames} > 0;
        $self->{duration} = $self->{dst_frames} / ($self->{dst_rate} || 75);
        # DST frame duration is 1/75 s; at FS bits/s one frame is FS/600
        # bytes per channel.  This is only used for informational size.
        $self->{raw_bytes_per_channel} =
            int($self->{dst_frames} * $self->{fs} / 600);
        $self->{audio_size} = $self->{raw_bytes_per_channel} * $self->{channels};
    }
    else {
        return undef unless $self->{audio_offset} > 0 && $self->{audio_size} > 0;
        $self->{duration} =
            $self->{audio_size} * 8 / ($self->{fs} * $self->{channels});
    }

    $self->{size} = $self->{audio_offset} + $self->{audio_size}
        unless $self->{is_dst};
    $self->{size} = $file_size if $self->{is_dst};

    return $self;
}

sub _parse_prop {
    my ($self, $fh, $data_off, $size, $total_end) = @_;

    return unless $size >= 4;
    seek($fh, $data_off, 0) or return;
    my $prop = _read_exact($fh, 4);
    return unless defined $prop && $prop eq 'SND ';

    my $pos = $data_off + 4;
    my $end = $data_off + $size;
    $end = $total_end if $end > $total_end;

    while ($pos + 12 <= $end) {
        seek($fh, $pos, 0) or last;
        my $hdr = _read_exact($fh, 12);
        last unless defined $hdr && length($hdr) == 12;
        my ($sid, $ssize) = unpack('a4 Q>', $hdr);
        my $sdata = $pos + 12;
        last if $sdata + $ssize > $end + 1;

        if ($sid eq 'FS  ' && $ssize >= 4) {
            seek($fh, $sdata, 0) or last;
            my $v = _read_exact($fh, 4);
            $self->{fs} = unpack('N', $v) if defined $v && length($v) == 4;
        }
        elsif ($sid eq 'CHNL' && $ssize >= 2) {
            seek($fh, $sdata, 0) or last;
            my $v = _read_exact($fh, 2);
            if (defined $v && length($v) == 2) {
                my $n = unpack('n', $v);
                $self->{channels} = $n if $n > 0 && $n <= 64;
                # Channel IDs are optional for our purposes; keep them for
                # diagnostics only.
                if ($ssize >= 2 + 4 * $n) {
                    seek($fh, $sdata + 2, 0);
                    my $ids = _read_exact($fh, 4 * $n);
                    if (defined $ids && length($ids) == 4 * $n) {
                        $self->{channel_ids} = [ unpack('(a4)*', $ids) ];
                    }
                }
            }
        }
        elsif ($sid eq 'CMPR' && $ssize >= 5) {
            seek($fh, $sdata, 0) or last;
            my $v = _read_exact($fh, 4);
            if (defined $v && length($v) == 4) {
                $self->{compression} = $v;
                $self->{is_dst} = 1 if $v eq 'DST ';
            }
            # Compression name follows the 4-byte type + 1-byte count.
            if ($ssize >= 5) {
                seek($fh, $sdata + 4, 0);
                my $cnt = _read_exact($fh, 1);
                if (defined $cnt && length($cnt) == 1) {
                    my $n = unpack('C', $cnt);
                    if ($n > 0 && $n < $self->{max_tag_size}) {
                        seek($fh, $sdata + 5, 0);
                        my $name = _read_exact($fh, $n);
                        $self->{compression_name} = _decode_text($name)
                            if defined $name;
                    }
                }
            }
            $self->{is_dst} = 1
                if ($self->{compression} && $self->{compression} eq 'DST ');
        }
        elsif ($sid eq 'ID3 ' || $sid eq 'id3 ') {
            push @{ $self->{id3_chunks} }, {
                offset => $sdata,
                size   => $ssize,
            };
        }

        $pos = $sdata + $ssize + ($ssize % 2 ? 1 : 0);
    }
}

sub _parse_dst {
    my ($self, $fh, $data_off, $size, $total_end) = @_;

    my $pos = $data_off;
    my $end = $data_off + $size;
    $end = $total_end if $end > $total_end;

    while ($pos + 12 <= $end) {
        seek($fh, $pos, 0) or last;
        my $hdr = _read_exact($fh, 12);
        last unless defined $hdr && length($hdr) == 12;
        my ($sid, $ssize) = unpack('a4 Q>', $hdr);
        my $sdata = $pos + 12;
        last if $sdata + $ssize > $end + 1;

        if ($sid eq 'FRTE' && $ssize >= 6) {
            seek($fh, $sdata, 0) or last;
            my $v = _read_exact($fh, 6);
            if (defined $v && length($v) == 6) {
                my ($frames, $rate) = unpack('N n', $v);
                $self->{dst_frames} = $frames if $frames > 0;
                $self->{dst_rate}   = $rate   if $rate > 0;
            }
            # FRTE is required to be the first DST subchunk.  Once we have
            # it, the remaining DSTF frames can be skipped as a whole.
            return 1 if $self->{dst_frames};
        }
        # DSTF/DSTC payloads are intentionally skipped.

        $pos = $sdata + $ssize + ($ssize % 2 ? 1 : 0);
    }
}

sub _parse_diin {
    my ($self, $fh, $data_off, $size, $total_end) = @_;

    my $pos = $data_off;
    my $end = $data_off + $size;
    $end = $total_end if $end > $total_end;

    while ($pos + 12 <= $end) {
        seek($fh, $pos, 0) or last;
        my $hdr = _read_exact($fh, 12);
        last unless defined $hdr && length($hdr) == 12;
        my ($sid, $ssize) = unpack('a4 Q>', $hdr);
        my $sdata = $pos + 12;
        last if $sdata + $ssize > $end + 1;

        if (($sid eq 'DIAR' || $sid eq 'DITI') && $ssize >= 4) {
            seek($fh, $sdata, 0) or last;
            my $lenbuf = _read_exact($fh, 4);
            if (defined $lenbuf && length($lenbuf) == 4) {
                my $count = unpack('N', $lenbuf);
                if ($count > 0 && $count <= $ssize - 4
                    && $count <= $self->{max_tag_size})
                {
                    seek($fh, $sdata + 4, 0) or last;
                    my $txt = _read_exact($fh, $count);
                    if (defined $txt) {
                        my $decoded = _decode_text($txt);
                        if ($sid eq 'DIAR') {
                            $self->{diar} = $decoded;
                        }
                        else {
                            $self->{diti} = $decoded;
                        }
                    }
                }
            }
        }

        $pos = $sdata + $ssize + ($ssize % 2 ? 1 : 0);
    }
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

sub _file_size {
    my ($fh) = @_;
    my @st = stat($fh);
    return $st[7] if @st;
    my $pos = tell($fh);
    seek($fh, 0, 2);
    my $end = tell($fh);
    seek($fh, $pos, 0) if defined $pos;
    return $end;
}

sub _decode_text {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    my $copy = $bytes;
    my $out;
    eval {
        $out = Encode::decode('UTF-8', $copy, Encode::FB_CROAK);
        1;
    };
    return $out if defined $out;
    return Encode::decode('ISO-8859-1', $bytes);
}

1;
